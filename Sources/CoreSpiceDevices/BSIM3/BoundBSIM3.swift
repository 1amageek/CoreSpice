import CoreSpiceCompactModels
import CoreSpiceIR
import Synchronization

/// Original BSIM3 equations mapped to the compiled physical and private nodes.
public final class BoundBSIM3: TransientSessionDevice, TerminalInitialConditionDevice, NoisyDevice {
    public let instance: Instance
    public let initialNodeVoltages: [Node: Double]
    public let diagnostics: [BSIM3Diagnostic]
    private let indices: SIMD8<Int>
    private let csrIndices: SIMD64<Int>
    private let nodeCount: Int
    private let multiplier: Double
    private let drainPrime: Node
    private let sourcePrime: Node
    private struct State {
        let evaluator: BSIM3Evaluator
        var transientActive = false
    }
    private let state: Mutex<State>

    init(instance: Instance, evaluator: BSIM3Evaluator, multiplier: Double, initialConditions: SIMD3<Double>?,
         indices: SIMD8<Int>, csrIndices: SIMD64<Int>) throws {
        self.instance = instance
        self.indices = indices
        self.csrIndices = csrIndices
        nodeCount = evaluator.topology.nodeCount
        self.multiplier = multiplier
        let topology = evaluator.topology
        drainPrime = topology.drainPrime > 4 ? instance.ownedNodes[topology.drainPrime - 5] : instance.nodes[0]
        sourcePrime = topology.sourcePrime > 4 ? instance.ownedNodes[topology.sourcePrime - 5] : instance.nodes[2]
        diagnostics = evaluator.diagnostics
        var initialVoltages: [Node: Double] = [:]
        if let initial = initialConditions {
            let relative = [initial[0], initial[1], 0, initial[2]]
            var sourceOffset: Double?
            for index in 0..<4 where instance.nodes[index] == .ground {
                let anchor = -relative[index]
                if let existing = sourceOffset, existing != anchor {
                    throw BSIM3Error.invalidConfiguration("Terminal IC conflicts at ground")
                }
                sourceOffset = anchor
            }
            let offset = sourceOffset ?? 0
            for index in 0..<4 {
                let value = relative[index] + offset
                if let existing = initialVoltages[instance.nodes[index]], existing != value {
                    throw BSIM3Error.invalidConfiguration("Terminal IC conflicts at aliased ports")
                }
                initialVoltages[instance.nodes[index]] = value
            }
            let topology = evaluator.topology
            if topology.drainPrime > 4 {
                initialVoltages[instance.ownedNodes[topology.drainPrime - 5]] = relative[0] + offset
            }
            if topology.sourcePrime > 4 {
                initialVoltages[instance.ownedNodes[topology.sourcePrime - 5]] = offset
            }
        }
        initialNodeVoltages = initialVoltages
        state = Mutex(State(evaluator: evaluator))
    }

    public func stampDC(into stamper: inout MatrixStamper, state solution: SolutionState) throws {
        let bias = try biases(solution)
        let evaluation = try state.withLock { try $0.evaluator.evaluate(bias: bias, analysis: .dc, minimumJunctionConductance: 1e-12) }
        try stamp(evaluation, into: &stamper)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state solution: SolutionState, omega: Double) throws {
        let bias = try biases(solution)
        let evaluation = try state.withLock { try $0.evaluator.evaluate(bias: bias, analysis: .ac(angularFrequency: omega), minimumJunctionConductance: 1e-12) }
        let real = evaluation.realJacobian * multiplier
        let imaginary = evaluation.imaginaryJacobian * multiplier
        guard finite(real), finite(imaginary) else { throw BSIM3Error.nonFiniteEvaluation }
        for row in 1...nodeCount where indices[row] >= 0 {
            for column in 1...nodeCount where indices[column] >= 0 {
                let slot = row * 8 + column
                stamper.stampMatrix(indices[row], indices[column], real[slot], imaginary[slot])
            }
        }
    }

    public func beginTransientSession(initialState: SolutionState) throws {
        let bias = try biases(initialState)
        try state.withLock { owner in
            guard !owner.transientActive else { throw BSIM3DeviceError.transientSessionAlreadyActive(instance.name) }
            try owner.evaluator.initializeHistory(at: bias)
            owner.transientActive = true
        }
    }

    public func endTransientSession() { state.withLock { $0.transientActive = false } }

    public func stampTransient(into stamper: inout MatrixStamper, state solution: SolutionState,
                               integration: IntegrationState) throws {
        let bias = try biases(solution)
        let evaluation = try state.withLock { owner in
            guard owner.transientActive else { throw BSIM3DeviceError.transientSessionRequired(instance.name) }
            return try owner.evaluator.evaluate(bias: bias, analysis: analysis(integration), minimumJunctionConductance: 1e-12)
        }
        try stamp(evaluation, into: &stamper)
    }

    public func commitTransientStep(state solution: SolutionState, integration: IntegrationState) throws {
        let bias = try biases(solution)
        try state.withLock { owner in
            guard owner.transientActive else { throw BSIM3DeviceError.transientSessionRequired(instance.name) }
            // Newton residual stamps and concurrent DC/AC can invalidate a trial
            // token. Acceptance owns this atomic re-evaluation and commit.
            let accepted = try owner.evaluator.evaluate(bias: bias, analysis: analysis(integration), minimumJunctionConductance: 1e-12)
            guard finite(accepted.realJacobian * multiplier), finite(accepted.rhs * multiplier) else {
                throw BSIM3Error.nonFiniteEvaluation
            }
            try owner.evaluator.commit(token: accepted.token)
        }
    }

    public func noiseContributions(state solution: SolutionState, frequency: Double) throws -> [NoiseSource] {
        let bias = try biases(solution)
        let spectrum = try state.withLock {
            try $0.evaluator.noiseSpectrum(bias: bias, frequency: frequency, minimumJunctionConductance: 1e-12)
        }.currentSpectralDensities * multiplier
        guard finite(spectrum) else { throw BSIM3Error.nonFiniteEvaluation }
        let positive = [drainPrime, sourcePrime, drainPrime, drainPrime]
        let negative = [instance.nodes[0], instance.nodes[2], sourcePrime, sourcePrime]
        let names = ["rd", "rs", "id", "1overf"]
        return (0..<4).map { index in
            NoiseSource(name: "\(instance.name)_\(names[index])", positiveNode: positive[index],
                        negativeNode: negative[index], currentSpectralDensity: spectrum[index])
        }
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        // The solver checks every compiled update and the full physical residual,
        // including auxiliary equations, after re-stamping this same current law.
        .converged
    }

    private func biases(_ solution: SolutionState) throws -> SIMD8<Double> {
        var values = SIMD8<Double>(repeating: 0)
        for index in 1...nodeCount where indices[index] >= 0 {
            values[index] = try solution.checkedValue(at: indices[index])
        }
        return values
    }

    private func analysis(_ integration: IntegrationState) -> BSIM3Analysis {
        switch integration.method {
        case .backwardEuler: .backwardEuler(timeStep: integration.timeStep)
        case .trapezoidal: .trapezoidal(timeStep: integration.timeStep)
        }
    }

    private func finite<V: SIMD>(_ values: V) -> Bool where V.Scalar == Double {
        for index in 0..<V.scalarCount where !values[index].isFinite { return false }
        return true
    }

    private func stamp(_ evaluation: BSIM3Evaluation, into stamper: inout MatrixStamper) throws {
        let matrix = evaluation.realJacobian * multiplier
        let rhs = evaluation.rhs * multiplier
        guard finite(matrix), finite(rhs) else { throw BSIM3Error.nonFiniteEvaluation }
        for row in 1...nodeCount where indices[row] >= 0 {
            stamper.stampRHS(indices[row], rhs[row])
            for column in 1...nodeCount where indices[column] >= 0 {
                let slot = row * 8 + column
                if let direct = stamper.stampValue, csrIndices[slot] >= 0 {
                    direct(csrIndices[slot], matrix[slot])
                } else { stamper.stampMatrix(indices[row], indices[column], matrix[slot]) }
            }
        }
    }
}

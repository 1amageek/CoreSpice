import CoreSpiceCompactModels
import CoreSpiceIR
import Synchronization

/// Original BSIM4 equations mapped to the compiled physical and private nodes.
public final class BoundBSIM4: TransientSessionDevice, TerminalInitialConditionDevice, NoiseAnalysisAdmissionDevice, OutputReferredNoisyDevice {
    public let instance: Instance
    public let initialNodeVoltages: [Node: Double]
    public let diagnostics: [BSIM4Diagnostic]
    private let indices: SIMD16<Int>
    private let csrIndices: BSIM4StampMapping
    private let nodeCount: Int
    private let multiplier: Double
    public let topology: BSIM4Topology
    public let preparationPolicy: BSIM4PreparationPolicy
    private struct State {
        let evaluator: any BSIM4Evaluating
        var transientActive = false
    }
    private let state: Mutex<State>

    init(instance: Instance, prepared: BSIM4PreparedDevice, indices: SIMD16<Int>, csrIndices: BSIM4StampMapping) throws {
        self.instance = instance
        self.indices = indices
        self.csrIndices = csrIndices
        nodeCount = prepared.evaluator.topology.nodeCount
        multiplier = prepared.multiplier
        let topology = prepared.evaluator.topology
        self.topology = topology
        preparationPolicy = prepared.policy
        diagnostics = prepared.evaluator.diagnostics
        var initialVoltages: [Node: Double] = [:]
        if let initial = prepared.initialConditions {
            let relative = [initial[0], initial[1], 0, initial[2]]
            var sourceOffset: Double?
            for index in 0..<4 where instance.nodes[index] == .ground {
                let anchor = -relative[index]
                if let existing = sourceOffset, existing != anchor {
                    throw BSIM4Error.invalidConfiguration("Terminal IC conflicts at ground")
                }
                sourceOffset = anchor
            }
            let offset = sourceOffset ?? 0
            for index in 0..<4 {
                let value = relative[index] + offset
                if let existing = initialVoltages[instance.nodes[index]], existing != value {
                    throw BSIM4Error.invalidConfiguration("Terminal IC conflicts at aliased ports")
                }
                initialVoltages[instance.nodes[index]] = value
            }
            for (role, terminal) in [(topology.drainPrime, 0), (topology.sourcePrime, 2),
                (topology.gatePrime, 1), (topology.gateMid, 1), (topology.bodyPrime, 3),
                (topology.drainBody, 3), (topology.sourceBody, 3)] where role > 4 {
                initialVoltages[instance.ownedNodes[role - 5]] = relative[terminal] + offset
            }
            if topology.chargeNode > 4 { initialVoltages[instance.ownedNodes[topology.chargeNode - 5]] = 0 }
        }
        initialNodeVoltages = initialVoltages
        state = Mutex(State(evaluator: prepared.evaluator))
    }

    public func stampDC(into stamper: inout MatrixStamper, state solution: SolutionState) throws {
        let bias = try biases(solution)
        let evaluation = try state.withLock { try $0.evaluator.evaluate(bias: bias, analysis: .dc, minimumJunctionConductance: 1e-12) }
        try stamp(evaluation, into: &stamper)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state solution: SolutionState, omega: Double) throws {
        let bias = try biases(solution)
        let evaluation = try state.withLock { try $0.evaluator.evaluate(bias: bias, analysis: .ac(angularFrequency: omega), minimumJunctionConductance: 1e-12) }
        try validateScaled(evaluation)
        for row in 1...nodeCount where indices[row] >= 0 {
            for column in 1...nodeCount where indices[column] >= 0 {
                let slot = row * 16 + column
                stamper.stampMatrix(indices[row], indices[column], evaluation.realJacobian[slot] * multiplier,
                                    evaluation.imaginaryJacobian[slot] * multiplier)
            }
        }
        if topology.chargeNode > 4 {
            let index = indices[topology.chargeNode]
            // Original AC NQS is implicit; this reserved coordinate is q_ac=0.
            stamper.stampMatrix(index, index, 1, 0)
        }
    }

    public func beginTransientSession(initialState: SolutionState) throws {
        let bias = try biases(initialState)
        try state.withLock { owner in
            guard !owner.transientActive else { throw BSIM4DeviceError.transientSessionAlreadyActive(instance.name) }
            try owner.evaluator.initializeHistory(at: bias)
            owner.transientActive = true
        }
    }

    public func endTransientSession() { state.withLock { $0.transientActive = false } }

    public func stampTransient(into stamper: inout MatrixStamper, state solution: SolutionState,
                               integration: IntegrationState) throws {
        let bias = try biases(solution)
        let evaluation = try state.withLock { owner in
            guard owner.transientActive else { throw BSIM4DeviceError.transientSessionRequired(instance.name) }
            return try owner.evaluator.evaluate(bias: bias, analysis: analysis(integration), minimumJunctionConductance: 1e-12)
        }
        try stamp(evaluation, into: &stamper)
    }

    public func commitTransientStep(state solution: SolutionState, integration: IntegrationState) throws {
        let bias = try biases(solution)
        try state.withLock { owner in
            guard owner.transientActive else { throw BSIM4DeviceError.transientSessionRequired(instance.name) }
            // Newton residual stamps and concurrent DC/AC can invalidate a trial
            // token. Acceptance owns this atomic re-evaluation and commit.
            let accepted = try owner.evaluator.evaluate(bias: bias, analysis: analysis(integration), minimumJunctionConductance: 1e-12)
            try validateScaled(accepted)
            try owner.evaluator.commit(token: accepted.token)
        }
    }

    public var noiseTransferNodes: [Node] { instance.nodes + instance.ownedNodes }

    public func validateNoiseAnalysis() throws {
        guard topology.noiseRequested else { throw BSIM4Error.noiseNotPrepared }
    }

    public func outputNoiseContributions(state solution: SolutionState, frequency: Double,
                                         gains: NoiseTransferGains) throws -> [OutputNoiseSource] {
        let bias = try biases(solution)
        var real = SIMD16<Double>(repeating: 0), imaginary = SIMD16<Double>(repeating: 0)
        for (index, node) in noiseTransferNodes.enumerated() {
            let gain = try gains.gain(at: node)
            real[index + 1] = gain.real; imaginary[index + 1] = gain.imaginary
        }
        let spectrum = try state.withLock { owner in
            try owner.evaluator.noiseSpectrum(bias: bias, frequency: frequency, gainReal: real,
                gainImaginary: imaginary, minimumJunctionConductance: 1e-12)
        }.outputSpectralDensities
        let names = ["rd", "rs", "rg", "rbps", "rbpd", "rbpb", "rbsb", "rbdb", "id", "1overf", "igs", "igd", "igb", "corl"]
        return try names.enumerated().map { index, name in
            let value = spectrum[index] * multiplier
            guard value.isFinite, value >= 0 else { throw BSIM4Error.nonFiniteEvaluation }
            return OutputNoiseSource(name: "\(instance.name)_\(name)", outputSpectralDensity: value)
        }
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        // The solver checks every compiled update and the full physical residual,
        // including auxiliary equations, after re-stamping this same current law.
        .converged
    }

    private func biases(_ solution: SolutionState) throws -> SIMD16<Double> {
        var values = SIMD16<Double>(repeating: 0)
        for index in 1...nodeCount where indices[index] >= 0 {
            values[index] = try solution.checkedValue(at: indices[index])
        }
        return values
    }

    private func analysis(_ integration: IntegrationState) -> BSIM4Analysis {
        switch integration.method {
        case .backwardEuler: .backwardEuler(timeStep: integration.timeStep)
        case .trapezoidal: .trapezoidal(timeStep: integration.timeStep)
        }
    }

    private func validateScaled(_ evaluation: BSIM4Evaluation) throws {
        for row in 1...nodeCount {
            guard (evaluation.rhs[row] * multiplier).isFinite else { throw BSIM4Error.nonFiniteEvaluation }
            for column in 1...nodeCount {
                let slot = row * 16 + column
                guard (evaluation.realJacobian[slot] * multiplier).isFinite,
                      (evaluation.imaginaryJacobian[slot] * multiplier).isFinite else {
                    throw BSIM4Error.nonFiniteEvaluation
                }
            }
        }
    }

    private func stamp(_ evaluation: BSIM4Evaluation, into stamper: inout MatrixStamper) throws {
        try validateScaled(evaluation)
        for row in 1...nodeCount where indices[row] >= 0 {
            stamper.stampRHS(indices[row], evaluation.rhs[row] * multiplier)
            for column in 1...nodeCount where indices[column] >= 0 {
                let slot = row * 16 + column
                if let direct = stamper.stampValue, csrIndices[slot] >= 0 {
                    direct(csrIndices[slot], evaluation.realJacobian[slot] * multiplier)
                } else { stamper.stampMatrix(indices[row], indices[column], evaluation.realJacobian[slot] * multiplier) }
            }
        }
    }
}

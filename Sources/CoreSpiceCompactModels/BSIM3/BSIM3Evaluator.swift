import CoreSpiceBSIM3
import Synchronization

/// Official Berkeley BSIM3 3.3.0 physics with one exclusively owned local context.
public final class BSIM3Evaluator: BSIM3Evaluating {
    private struct State {
        let handle: OpaquePointer
    }
    private let state: Mutex<State>
    public let topology: BSIM3Topology
    public let diagnostics: [BSIM3Diagnostic]

    public init(configuration: BSIM3Configuration) throws {
        guard configuration.version == "3.3.0" else { throw BSIM3Error.unsupportedVersion(configuration.version) }
        guard configuration.temperature.isFinite, configuration.temperature > 0,
              configuration.modelParameters.count <= 512, configuration.instanceParameters.count <= 32 else {
            throw BSIM3Error.invalidConfiguration("Temperature or parameter capacity is invalid")
        }
        guard let handle = cs_bsim3_create(configuration.polarity.rawValue, configuration.temperature) else {
            throw BSIM3Error.allocationFailure
        }
        // Initialization is exclusive before publication. Transfer the sole pointer
        // into Mutex after preparation; every subsequent access and free uses it.
        do {
            for (isModel, parameters) in [(true, configuration.modelParameters), (false, configuration.instanceParameters)] {
                var normalized = Set<String>()
                for (key, value) in parameters.sorted(by: { $0.key < $1.key }) {
                    let name = key.lowercased()
                    guard !name.isEmpty, name.utf8.count <= 64, !name.utf8.contains(0), normalized.insert(name).inserted else {
                        throw BSIM3Error.invalidParameter(name: key, model: isModel)
                    }
                    let status = name.withCString { cs_bsim3_parameter(handle, isModel ? 1 : 0, $0, value) }
                    guard status == CS_BSIM3_OK else { throw BSIM3Error.invalidParameter(name: key, model: isModel) }
                }
            }
            if var initial = configuration.initialConditions {
                let status = withUnsafeBytes(of: &initial) { bytes in
                    cs_bsim3_initial_conditions(handle, bytes.bindMemory(to: Double.self).baseAddress!)
                }
                guard status == CS_BSIM3_OK else { throw BSIM3Error.invalidConfiguration("Initial conditions must be finite") }
            }
            var local = CSBSIM3Topology()
            let status = cs_bsim3_prepare(handle, &local)
            let messages = String(cString: cs_bsim3_diagnostics(handle))
            guard status == CS_BSIM3_OK else { throw Self.error(status: status, diagnostics: messages) }
            // Reject non-finite derived model behavior before publishing an owner.
            var cold = SIMD8<Double>(repeating: 0)
            var probe = CSBSIM3Result()
            let preflight = withUnsafeBytes(of: &cold) { bytes in
                cs_bsim3_evaluate(handle, bytes.bindMemory(to: Double.self).baseAddress!, 0, 0, 0, 0, &probe)
            }
            guard preflight == CS_BSIM3_OK else { throw Self.error(status: preflight, diagnostics: messages) }
            self.topology = BSIM3Topology(nodeCount: Int(local.nodeCount), drainPrime: Int(local.drainPrime),
                                          sourcePrime: Int(local.sourcePrime), chargeNode: Int(local.chargeNode))
            self.diagnostics = messages.split(separator: "\n").map { BSIM3Diagnostic(String($0)) }
            self.state = Mutex(State(handle: handle))
        } catch {
            cs_bsim3_destroy(handle)
            throw error
        }
    }

    deinit { state.withLock { cs_bsim3_destroy($0.handle) } }

    public func evaluate(bias: SIMD8<Double>, analysis: BSIM3Analysis,
                         minimumJunctionConductance: Double = 1e-12) throws -> BSIM3Evaluation {
        var mode: Int32 = 0
        var frequency = 0.0
        var step = 0.0
        switch analysis {
        case .dc: break
        case .ac(let omega): mode = 1; frequency = omega
        case .backwardEuler(let dt): mode = 2; step = dt
        case .trapezoidal(let dt): mode = 3; step = dt
        }
        var values = bias
        var result = CSBSIM3Result()
        try state.withLock { owner in
            let status = withUnsafeBytes(of: &values) { bytes in
                cs_bsim3_evaluate(owner.handle, bytes.bindMemory(to: Double.self).baseAddress!, mode,
                                  frequency, step, minimumJunctionConductance, &result)
            }
            guard status == CS_BSIM3_OK else { throw Self.error(status: status, diagnostics: "Invalid evaluation input") }
        }
        return BSIM3Evaluation(residual: Self.vector(result.residual), rhs: Self.vector(result.rhs),
                               charge: Self.vector(result.charge), realJacobian: Self.vector(result.real),
                               imaginaryJacobian: Self.vector(result.imaginary), states: Self.vector(result.states),
                               operatingPoint: Self.vector(result.operatingPoint), token: result.token)
    }

    public func noiseSpectrum(bias: SIMD8<Double>, frequency: Double,
                              minimumJunctionConductance: Double = 1e-12) throws -> BSIM3NoiseSpectrum {
        var values = bias
        var densities = SIMD4<Double>(repeating: 0)
        try state.withLock { owner in
            let status = withUnsafeBytes(of: &values) { input in
                withUnsafeMutableBytes(of: &densities) { output in
                    cs_bsim3_noise_spectrum(owner.handle, input.bindMemory(to: Double.self).baseAddress!,
                        frequency, minimumJunctionConductance, output.bindMemory(to: Double.self).baseAddress!)
                }
            }
            guard status == CS_BSIM3_OK else { throw Self.error(status: status, diagnostics: "Invalid noise frequency or effective geometry") }
        }
        return BSIM3NoiseSpectrum(currentSpectralDensities: densities)
    }

    public func initializeHistory(at bias: SIMD8<Double>) throws {
        var values = bias
        try state.withLock { owner in
            let status = withUnsafeBytes(of: &values) { bytes in
                cs_bsim3_initialize_history(owner.handle, bytes.bindMemory(to: Double.self).baseAddress!)
            }
            guard status == CS_BSIM3_OK else { throw Self.error(status: status, diagnostics: "Invalid initial bias") }
        }
    }

    public func commit(token: UInt64) throws {
        try state.withLock { owner in
            let status = cs_bsim3_commit(owner.handle, token)
            guard status == CS_BSIM3_OK else { throw Self.error(status: status, diagnostics: "Invalid transient trial") }
        }
    }

    public func acceptedStates() -> SIMD32<Double> {
        var values = SIMD32<Double>(repeating: 0)
        state.withLock { owner in
            withUnsafeMutableBytes(of: &values) { bytes in
                cs_bsim3_accepted_states(owner.handle, bytes.bindMemory(to: Double.self).baseAddress!)
            }
        }
        return values
    }

    private static func error(status: Int32, diagnostics: String) -> BSIM3Error {
        switch Int(status) {
        case CS_BSIM3_NUMERICAL: .nonFiniteEvaluation
        case CS_BSIM3_HISTORY: .invalidHistory
        case CS_BSIM3_DIAGNOSTICS: .diagnosticCapacityExceeded
        case CS_BSIM3_MEMORY: .allocationFailure
        default: .modelRejected(diagnostics)
        }
    }

    // Imported fixed C arrays and SIMD values have contiguous Double storage.
    // The scoped borrow never escapes; initialized ABI values are copied into
    // an independently owned SIMD result without heap allocation or alignment casts.
    private static func vector<T, V: SIMD>(_ value: T) -> V where V.Scalar == Double {
        withUnsafeBytes(of: value) { bytes in
            let source = bytes.bindMemory(to: Double.self)
            precondition(source.count == V.scalarCount)
            var result = V(repeating: 0)
            for index in 0..<V.scalarCount { result[index] = source[index] }
            return result
        }
    }
}

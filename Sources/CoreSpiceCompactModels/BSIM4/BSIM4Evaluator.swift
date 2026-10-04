import CoreSpiceBSIM4
import Synchronization

/// Exact Berkeley 4.8.3 physics with one exclusively retained synchronized C owner.
public final class BSIM4Evaluator: BSIM4Evaluating {
    private struct State { let handle: OpaquePointer }
    private let state: Mutex<State>
    public let topology: BSIM4Topology
    public let diagnostics: [BSIM4Diagnostic]

    public init(configuration: BSIM4Configuration) throws {
        guard configuration.version == "4.8.3" else { throw BSIM4Error.unsupportedVersion(configuration.version) }
        guard configuration.temperature.isFinite, configuration.temperature > 0,
              configuration.modelParameters.count <= 886, configuration.instanceParameters.count <= 36 else {
            throw BSIM4Error.invalidConfiguration("Temperature or original parameter capacity is invalid")
        }
        var localHandle: OpaquePointer?
        let createStatus = configuration.version.withCString {
            cs_bsim4_create(configuration.polarity.rawValue, $0, configuration.temperature,
                            configuration.noiseRequested ? 1 : 0, &localHandle)
        }
        guard createStatus == CS_BSIM4_OK, let handle = localHandle else {
            throw Self.error(createStatus, "Cannot allocate the original model context")
        }
        // Initialization is exclusive before publication; all later accesses and free share Mutex.
        do {
            guard cs_bsim4_set_stress_budget(handle, configuration.maximumStressIterations) == CS_BSIM4_OK else {
                throw BSIM4Error.resourceBudgetExceeded
            }
            for (model, parameters) in [(true, configuration.modelParameters), (false, configuration.instanceParameters)] {
                var names = Set<String>()
                for (key, value) in parameters.sorted(by: { $0.key < $1.key }) {
                    let name = key.lowercased()
                    guard !name.isEmpty, name.utf8.count <= 64, !name.utf8.contains(0), names.insert(name).inserted else {
                        throw BSIM4Error.invalidParameter(name: key, model: model)
                    }
                    let status = name.withCString { cs_bsim4_parameter(handle, model ? 1 : 0, $0, value) }
                    guard status == CS_BSIM4_OK else { throw BSIM4Error.invalidParameter(name: key, model: model) }
                }
            }
            if var initial = configuration.initialConditions {
                let status = withUnsafeBytes(of: &initial) {
                    cs_bsim4_initial_conditions(handle, $0.bindMemory(to: Double.self).baseAddress!)
                }
                guard status == CS_BSIM4_OK else { throw BSIM4Error.invalidConfiguration("Initial conditions must be finite") }
            }
            var local = CSBSIM4Topology()
            let status = cs_bsim4_prepare(handle, &local)
            guard status == CS_BSIM4_OK else { throw Self.error(status, String(cString: cs_bsim4_diagnostics(handle))) }
            var bias = SIMD16<Double>(repeating: 0)
            var probe = CSBSIM4Result()
            let preflight = withUnsafeBytes(of: &bias) {
                cs_bsim4_evaluate(handle, $0.bindMemory(to: Double.self).baseAddress!, 0, 0, 0, 0, &probe)
            }
            let messages = String(cString: cs_bsim4_diagnostics(handle))
            guard preflight == CS_BSIM4_OK else { throw Self.error(preflight, messages) }
            self.topology = BSIM4Topology(nodeCount: Int(local.nodeCount), drainPrime: Int(local.drainPrime),
                sourcePrime: Int(local.sourcePrime), gatePrime: Int(local.gatePrime), gateMid: Int(local.gateMid),
                bodyPrime: Int(local.bodyPrime), drainBody: Int(local.drainBody), sourceBody: Int(local.sourceBody),
                chargeNode: Int(local.chargeNode), noiseRequested: local.noiseRequested != 0,
                maintainerUnsupportedNoiseMode: local.maintainerUnsupportedNoiseMode != 0)
            self.diagnostics = messages.split(separator: "\n").map { BSIM4Diagnostic(String($0)) }
            self.state = Mutex(State(handle: handle))
        } catch {
            cs_bsim4_destroy(handle)
            throw error
        }
    }
    deinit { state.withLock { cs_bsim4_destroy($0.handle) } }

    public func evaluate(bias: SIMD16<Double>, analysis: BSIM4Analysis,
                         minimumJunctionConductance: Double = 1e-12) throws -> BSIM4Evaluation {
        var mode: Int32 = 0, omega = 0.0, step = 0.0
        switch analysis {
        case .dc: break
        case .ac(let value): mode = 1; omega = value
        case .backwardEuler(let value): mode = 2; step = value
        case .trapezoidal(let value): mode = 3; step = value
        }
        var input = bias, result = CSBSIM4Result()
        try state.withLock { owner in
            cs_bsim4_invalidate_trial(owner.handle)
            try Self.validatePadding(input)
            let status = withUnsafeBytes(of: &input) {
                cs_bsim4_evaluate(owner.handle, $0.bindMemory(to: Double.self).baseAddress!, mode,
                                  omega, step, minimumJunctionConductance, &result)
            }
            guard status == CS_BSIM4_OK else { throw Self.error(status, "Invalid original evaluation input") }
        }
        return BSIM4Evaluation(residual: Self.vector(result.residual, count: 13), rhs: Self.vector(result.rhs, count: 13),
            charge: Self.vector(result.charge, count: 13), realJacobian: Self.matrix(result.real),
            imaginaryJacobian: Self.matrix(result.imaginary), states: Self.vector(result.states, count: 29),
            operatingPoint: Self.vector(result.operatingPoint, count: 8),
            intrinsicCharges: Self.vector(result.intrinsicCharges, count: 4), token: result.token)
    }
    public func initializeHistory(at bias: SIMD16<Double>) throws {
        var input = bias
        try state.withLock { owner in
            cs_bsim4_invalidate_trial(owner.handle)
            try Self.validatePadding(input)
            let status = withUnsafeBytes(of: &input) {
                cs_bsim4_initialize_history(owner.handle, $0.bindMemory(to: Double.self).baseAddress!)
            }
            guard status == CS_BSIM4_OK else { throw Self.error(status, "Invalid initial bias") }
        }
    }
    public func commit(token: UInt64) throws {
        try state.withLock { owner in
            let status = cs_bsim4_commit(owner.handle, token)
            guard status == CS_BSIM4_OK else { throw Self.error(status, "Invalid transient token") }
        }
    }
    public func acceptedStates() throws -> SIMD32<Double> {
        var output = SIMD32<Double>(repeating: 0)
        try state.withLock { owner in
            let status = withUnsafeMutableBytes(of: &output) {
                cs_bsim4_accepted_states(owner.handle, $0.bindMemory(to: Double.self).baseAddress!)
            }
            guard status == CS_BSIM4_OK else { throw Self.error(status, "Accepted history is not initialized") }
        }
        return output
    }
    private static func validatePadding(_ value: SIMD16<Double>) throws {
        guard value[13] == 0, value[14] == 0, value[15] == 0 else {
            throw BSIM4Error.invalidConfiguration("Inactive padded slots must be zero")
        }
    }
    private static func error(_ status: Int32, _ message: String) -> BSIM4Error {
        switch Int(status) {
        case CS_BSIM4_RESOURCE: .resourceBudgetExceeded
        case CS_BSIM4_MEMORY: .allocationFailure
        case CS_BSIM4_NUMERICAL: .nonFiniteEvaluation
        case CS_BSIM4_HISTORY: .invalidHistory
        case CS_BSIM4_DIAGNOSTICS: .diagnosticCapacityExceeded
        default: .modelRejected(message)
        }
    }
    // C arrays are initialized contiguous Double tuples. Scoped borrows never escape;
    // copies produce independent fixed SIMD owners with no heap buffer or unchecked cast.
    private static func vector<T, V: SIMD>(_ value: T, count: Int) -> V where V.Scalar == Double {
        withUnsafeBytes(of: value) { bytes in
            let source = bytes.bindMemory(to: Double.self)
            precondition(source.count == count && count <= V.scalarCount)
            var result = V(repeating: 0)
            for index in 0..<count { result[index] = source[index] }
            return result
        }
    }
    private static func matrix<T>(_ value: T) -> BSIM4Matrix {
        withUnsafeBytes(of: value) { bytes in
            let source = bytes.bindMemory(to: Double.self)
            precondition(source.count == 169)
            var result = BSIM4Matrix()
            for row in 0..<13 { for column in 0..<13 { result.set(row * 16 + column, source[row * 13 + column]) } }
            return result
        }
    }
}

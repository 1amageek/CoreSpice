import CoreSpiceBSIM4
import Synchronization
import CoreSpiceMOSContracts

/// Exact Berkeley 4.8.3 physics with one exclusively retained synchronized C owner.
public final class BSIM4Evaluator: BSIM4Evaluating {
    /// Exact payload requested by the linked C owner's single allocation.
    public static var ownerAllocationBytes: UInt64 { UInt64(cs_bsim4_owner_size()) }
    /// Declared Swift stored payload; heap/allocator metadata is excluded.
    public static var storedPayloadBytes: UInt64 {
        UInt64(MemoryLayout<Mutex<State>>.stride + MemoryLayout<BSIM4Topology>.stride
            + MemoryLayout<[BSIM4Diagnostic]>.stride + 3 * MemoryLayout<UInt64>.stride)
    }
    private struct State { let handle: OpaquePointer }
    private let state: Mutex<State>
    public let topology: BSIM4Topology
    public let diagnostics: [BSIM4Diagnostic]

    public let preparationTemporaryBytes: UInt64
    public let diagnosticStorageBytes: UInt64
    public let preparationWorkUnits: UInt64

    public convenience init(configuration: BSIM4Configuration) throws {
        let limits = try CompactModelPreparationStorage.standaloneLimits(
            parameterCapacity: 922, diagnosticStride: MemoryLayout<BSIM4Diagnostic>.stride,
            ownerBytes: Self.ownerAllocationBytes + Self.storedPayloadBytes)
        try self.init(configuration: configuration, preparationLimits: limits, preparationControl: nil)
    }

    /// Native construction checks explicit preparation storage/work before publication.
    public init(configuration: BSIM4Configuration, preparationLimits: MOSPreparationLimits,
                preparationControl: (any MOSPreparationControlling)?) throws {
        var storage = CompactModelPreparationStorage(limits: preparationLimits, control: preparationControl)
        try storage.charge()
        guard Self.ownerAllocationBytes + Self.storedPayloadBytes <= preparationLimits.maximumRetainedBytes else {
            throw MOSPreparationFailure.capacityExceeded
        }
        // The original C diagnostic buffer bounds text conversion before its exact length is known.
        try storage.check(32768)

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
            let parameterScopes = [(true, configuration.modelParameters), (false, configuration.instanceParameters)]
            try storage.admitScopeCapacity(parameterScopes.capacity)
            for (model, parameters) in parameterScopes {
                let ordered = try storage.ordered(parameters)
                let orderedBytes = try CompactModelPreparationStorage.bytes(ordered.capacity, of: (String, Double).self)
                try storage.check(CompactModelPreparationStorage.add(orderedBytes,
                    CompactModelPreparationStorage.bytes(parameters.count, of: String.self)))
                var names = Set<String>()
                names.reserveCapacity(parameters.count)
                let setBytes = try CompactModelPreparationStorage.bytes(names.capacity, of: String.self)
                var nameBytes: UInt64 = 0
                try storage.check(CompactModelPreparationStorage.add(orderedBytes, setBytes))
                for (key, value) in ordered {
                    try storage.charge()
                    guard !key.isEmpty, key.utf8.count <= 64, key.utf8.allSatisfy({ $0 > 0 && $0 < 128 }) else {
                        throw BSIM4Error.invalidParameter(name: key, model: model)
                    }
                    try storage.check(CompactModelPreparationStorage.add(orderedBytes,
                        CompactModelPreparationStorage.add(setBytes, nameBytes + UInt64(key.utf8.count))))
                    let name = key.lowercased()
                    guard names.insert(name).inserted else {
                        throw BSIM4Error.invalidParameter(name: key, model: model)
                    }
                    nameBytes += UInt64(name.utf8.count)
                    try storage.check(CompactModelPreparationStorage.add(orderedBytes,
                        CompactModelPreparationStorage.add(CompactModelPreparationStorage.bytes(names.capacity, of: String.self), nameBytes)))
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
            try storage.charge()
            let status = cs_bsim4_prepare(handle, &local)
            guard status == CS_BSIM4_OK else { throw Self.error(status, String(cString: cs_bsim4_diagnostics(handle))) }
            try storage.charge()
            var bias = SIMD16<Double>(repeating: 0)
            var probe = CSBSIM4Result()
            let preflight = withUnsafeBytes(of: &bias) {
                cs_bsim4_evaluate(handle, $0.bindMemory(to: Double.self).baseAddress!, 0, 0, 0, 0, &probe)
            }
            try storage.check(32768)
            let messages = String(cString: cs_bsim4_diagnostics(handle))
            guard preflight == CS_BSIM4_OK else { throw Self.error(preflight, messages) }
            self.topology = BSIM4Topology(nodeCount: Int(local.nodeCount), drainPrime: Int(local.drainPrime),
                sourcePrime: Int(local.sourcePrime), gatePrime: Int(local.gatePrime), gateMid: Int(local.gateMid),
                bodyPrime: Int(local.bodyPrime), drainBody: Int(local.drainBody), sourceBody: Int(local.sourceBody),
                chargeNode: Int(local.chargeNode), noiseRequested: local.noiseRequested != 0,
                maintainerUnsupportedNoiseMode: local.maintainerUnsupportedNoiseMode != 0)
            let lines = try storage.diagnosticLines(messages, diagnosticStride: MemoryLayout<BSIM4Diagnostic>.stride)
            // Retained diagnostics omit the separators kept in the temporary C message text.
            var diagnosticTextBytes: UInt64 = 0
            for line in lines {
                try storage.charge()
                diagnosticTextBytes = try CompactModelPreparationStorage.add(diagnosticTextBytes, UInt64(line.utf8.count))
            }
            let requestedDiagnostics = try CompactModelPreparationStorage.add(
                CompactModelPreparationStorage.bytes(lines.count, of: BSIM4Diagnostic.self), diagnosticTextBytes)
            guard requestedDiagnostics <= preparationLimits.maximumDiagnosticBytes,
                  Self.ownerAllocationBytes + Self.storedPayloadBytes + requestedDiagnostics <= preparationLimits.maximumRetainedBytes else {
                throw MOSPreparationFailure.capacityExceeded
            }
            var diagnostics: [BSIM4Diagnostic] = []
            diagnostics.reserveCapacity(lines.count)
            let arrayBytes = try CompactModelPreparationStorage.bytes(diagnostics.capacity, of: BSIM4Diagnostic.self)
            let viewsBytes = try CompactModelPreparationStorage.bytes(lines.capacity, of: Substring.self)
            let messageBytes = UInt64(messages.utf8.count)
            let admittedDiagnostics = try CompactModelPreparationStorage.add(arrayBytes, diagnosticTextBytes)
            guard admittedDiagnostics <= preparationLimits.maximumDiagnosticBytes,
                  Self.ownerAllocationBytes + Self.storedPayloadBytes + admittedDiagnostics <= preparationLimits.maximumRetainedBytes else {
                throw MOSPreparationFailure.capacityExceeded
            }
            try storage.check(CompactModelPreparationStorage.add(arrayBytes, viewsBytes + 2 * messageBytes))
            for line in lines {
                try storage.charge()
                diagnostics.append(BSIM4Diagnostic(String(line)))
            }
            let retainedDiagnostics = try CompactModelPreparationStorage.add(arrayBytes, diagnosticTextBytes)
            guard retainedDiagnostics <= preparationLimits.maximumDiagnosticBytes,
                  Self.ownerAllocationBytes + Self.storedPayloadBytes + retainedDiagnostics <= preparationLimits.maximumRetainedBytes else {
                throw MOSPreparationFailure.capacityExceeded
            }
            try preparationControl?.checkCancellation()
            self.diagnostics = diagnostics
            self.diagnosticStorageBytes = retainedDiagnostics
            self.preparationTemporaryBytes = storage.temporaryBytes
            self.preparationWorkUnits = storage.workUnits
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
    public func noiseSpectrum(bias: SIMD16<Double>, frequency: Double,
                              gainReal: SIMD16<Double>, gainImaginary: SIMD16<Double>,
                              minimumJunctionConductance: Double = 1e-12) throws -> BSIM4NoiseSpectrum {
        var input = bias, real = gainReal, imaginary = gainImaginary
        var output = SIMD16<Double>(repeating: 0)
        try state.withLock { owner in
            cs_bsim4_invalidate_trial(owner.handle)
            try Self.validatePadding(input)
            try Self.validatePadding(real)
            try Self.validatePadding(imaginary)
            let status = withUnsafeBytes(of: &input) { biasBytes in
                withUnsafeBytes(of: &real) { realBytes in
                    withUnsafeBytes(of: &imaginary) { imaginaryBytes in
                        withUnsafeMutableBytes(of: &output) { outputBytes in
                            cs_bsim4_noise_spectrum(owner.handle, biasBytes.bindMemory(to: Double.self).baseAddress!,
                                frequency, minimumJunctionConductance, realBytes.bindMemory(to: Double.self).baseAddress!,
                                imaginaryBytes.bindMemory(to: Double.self).baseAddress!, outputBytes.bindMemory(to: Double.self).baseAddress!)
                        }
                    }
                }
            }
            guard status == CS_BSIM4_OK else { throw Self.error(status, "Invalid original noise spectrum input") }
        }
        return BSIM4NoiseSpectrum(outputSpectralDensities: output)
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
        case CS_BSIM4_NOISE_UNPREPARED: .noiseNotPrepared
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

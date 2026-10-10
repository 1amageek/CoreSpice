import CoreSpiceBSIM3
import Synchronization
import CoreSpiceMOSContracts

/// Official Berkeley BSIM3 3.3.0 physics with one exclusively owned local context.
public final class BSIM3Evaluator: BSIM3Evaluating {
    /// Exact payload requested by the linked C owner's single allocation.
    public static var ownerAllocationBytes: UInt64 { UInt64(cs_bsim3_owner_size()) }
    /// Declared Swift stored payload; heap/allocator metadata is excluded.
    public static var storedPayloadBytes: UInt64 {
        UInt64(MemoryLayout<Mutex<State>>.stride + MemoryLayout<BSIM3Topology>.stride
            + MemoryLayout<[BSIM3Diagnostic]>.stride + 3 * MemoryLayout<UInt64>.stride)
    }
    private struct State {
        let handle: OpaquePointer
    }
    private let state: Mutex<State>
    public let topology: BSIM3Topology
    public let diagnostics: [BSIM3Diagnostic]

    public let preparationTemporaryBytes: UInt64
    public let diagnosticStorageBytes: UInt64
    public let preparationWorkUnits: UInt64

    public convenience init(configuration: BSIM3Configuration) throws {
        let limits = try CompactModelPreparationStorage.standaloneLimits(
            parameterCapacity: 544, diagnosticStride: MemoryLayout<BSIM3Diagnostic>.stride,
            ownerBytes: Self.ownerAllocationBytes + Self.storedPayloadBytes)
        try self.init(configuration: configuration, preparationLimits: limits, preparationControl: nil)
    }

    /// Native construction checks explicit preparation storage/work before publication.
    public init(configuration: BSIM3Configuration, preparationLimits: MOSPreparationLimits,
                preparationControl: (any MOSPreparationControlling)?) throws {
        var storage = CompactModelPreparationStorage(limits: preparationLimits, control: preparationControl)
        try storage.charge()
        guard Self.ownerAllocationBytes + Self.storedPayloadBytes <= preparationLimits.maximumRetainedBytes else {
            throw MOSPreparationFailure.capacityExceeded
        }
        // The original C diagnostic buffer bounds text conversion before its exact length is known.
        try storage.check(32768)

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
            let parameterScopes = [(true, configuration.modelParameters), (false, configuration.instanceParameters)]
            try storage.admitScopeCapacity(parameterScopes.capacity)
            for (isModel, parameters) in parameterScopes {
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
                        throw BSIM3Error.invalidParameter(name: key, model: isModel)
                    }
                    try storage.check(CompactModelPreparationStorage.add(orderedBytes,
                        CompactModelPreparationStorage.add(setBytes, nameBytes + UInt64(key.utf8.count))))
                    let name = key.lowercased()
                    guard names.insert(name).inserted else {
                        throw BSIM3Error.invalidParameter(name: key, model: isModel)
                    }
                    nameBytes += UInt64(name.utf8.count)
                    try storage.check(CompactModelPreparationStorage.add(orderedBytes,
                        CompactModelPreparationStorage.add(CompactModelPreparationStorage.bytes(names.capacity, of: String.self), nameBytes)))
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
            try storage.charge()
            let status = cs_bsim3_prepare(handle, &local)
            try storage.check(32768)
            let messages = String(cString: cs_bsim3_diagnostics(handle))
            guard status == CS_BSIM3_OK else { throw Self.error(status: status, diagnostics: messages) }
            // Reject non-finite derived model behavior before publishing an owner.
            try storage.charge()
            var cold = SIMD8<Double>(repeating: 0)
            var probe = CSBSIM3Result()
            let preflight = withUnsafeBytes(of: &cold) { bytes in
                cs_bsim3_evaluate(handle, bytes.bindMemory(to: Double.self).baseAddress!, 0, 0, 0, 0, &probe)
            }
            guard preflight == CS_BSIM3_OK else { throw Self.error(status: preflight, diagnostics: messages) }
            self.topology = BSIM3Topology(nodeCount: Int(local.nodeCount), drainPrime: Int(local.drainPrime),
                                          sourcePrime: Int(local.sourcePrime), chargeNode: Int(local.chargeNode))
            let lines = try storage.diagnosticLines(messages, diagnosticStride: MemoryLayout<BSIM3Diagnostic>.stride)
            // Retained diagnostics omit the separators kept in the temporary C message text.
            var diagnosticTextBytes: UInt64 = 0
            for line in lines {
                try storage.charge()
                diagnosticTextBytes = try CompactModelPreparationStorage.add(diagnosticTextBytes, UInt64(line.utf8.count))
            }
            let requestedDiagnostics = try CompactModelPreparationStorage.add(
                CompactModelPreparationStorage.bytes(lines.count, of: BSIM3Diagnostic.self), diagnosticTextBytes)
            guard requestedDiagnostics <= preparationLimits.maximumDiagnosticBytes,
                  Self.ownerAllocationBytes + Self.storedPayloadBytes + requestedDiagnostics <= preparationLimits.maximumRetainedBytes else {
                throw MOSPreparationFailure.capacityExceeded
            }
            var diagnostics: [BSIM3Diagnostic] = []
            diagnostics.reserveCapacity(lines.count)
            let arrayBytes = try CompactModelPreparationStorage.bytes(diagnostics.capacity, of: BSIM3Diagnostic.self)
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
                diagnostics.append(BSIM3Diagnostic(String(line)))
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

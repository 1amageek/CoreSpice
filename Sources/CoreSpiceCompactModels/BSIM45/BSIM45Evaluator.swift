import CoreSpiceBSIM45
import CoreSpiceMOSContracts
import Synchronization

/// One exact-release C allocation, serialized for its entire published lifetime.
public final class BSIM45Evaluator: BSIM45Evaluating {
    private struct State: ~Copyable { let handle: OpaquePointer }
    private let state: Mutex<State>
    private let identity = BSIM45TrialIdentity()
    public let topology: BSIM45Topology
    public let diagnostics: [BSIM45Diagnostic]
    public let preparationTemporaryBytes: UInt64
    public let diagnosticStorageBytes: UInt64
    public let preparationWorkUnits: UInt64
    public static var ownerAllocationBytes: UInt64 { UInt64(cs_bsim45_owner_size()) }
    public static var adaptationIdentity: String { String(cString: cs_bsim45_adaptation()) }
    /// Stored payload; Swift/C allocator metadata and borrowed configuration are excluded.
    public static var storedPayloadBytes: UInt64 {
        UInt64(MemoryLayout<Mutex<State>>.stride + MemoryLayout<BSIM45Topology>.stride
            + MemoryLayout<BSIM45TrialIdentity>.stride + MemoryLayout<[BSIM45Diagnostic]>.stride
            + 3 * MemoryLayout<UInt64>.stride)
    }
    public convenience init(configuration: BSIM45Configuration) throws {
        let diagnostic = UInt64(128 * (MemoryLayout<BSIM45Diagnostic>.stride + 192))
        let limits = try MOSPreparationLimits(maximumRetainedBytes: Self.ownerAllocationBytes + Self.storedPayloadBytes + diagnostic,
            maximumTemporaryBytes: diagnostic + 779 * 64, maximumDiagnosticBytes: diagnostic,
            maximumWorkUnits: UInt64(configuration.maximumStressIterations) + 2 * 779 + 2 * 128 + 2)
        try self.init(configuration: configuration, preparationLimits: limits, preparationControl: nil)
    }
    public init(configuration: BSIM45Configuration, preparationLimits: MOSPreparationLimits,
                preparationControl: (any MOSPreparationControlling)?) throws {
        var storage = CompactModelPreparationStorage(limits: preparationLimits, control: preparationControl)
        try storage.admitScopeCapacity(0)
        try storage.charge()
        guard Self.ownerAllocationBytes + Self.storedPayloadBytes <= preparationLimits.maximumRetainedBytes else {
            throw MOSPreparationFailure.capacityExceeded
        }
        var conditions = CSBSIM45Conditions(maximumOwnerBytes: Int(Self.ownerAllocationBytes),
            maximumStressIterations: configuration.maximumStressIterations, maximumDiagnostics: 128,
            ambientKelvin: configuration.temperature, nominalKelvin: configuration.nominalTemperature,
            noiseTopology: configuration.noiseRequested ? 1 : 0)
        var local: OpaquePointer?
        let status = configuration.version.withCString { cs_bsim45_create($0, 2, configuration.polarity.rawValue, &conditions, &local) }
        try Self.check(status)
        guard let handle = local else { throw BSIM45Error.allocationFailure }
        do {
            for role in [MOSParameterRole.model, .instance] {
                let values = role == .model ? configuration.modelParameters : configuration.instanceParameters
                guard values.count <= 779 else { throw BSIM45Error.invalidParameter }
                var seen = Set<Int32>()
                try storage.check(UInt64(values.count * MemoryLayout<Int32>.stride))
                seen.reserveCapacity(values.count)
                try storage.check(UInt64(seen.capacity * MemoryLayout<Int32>.stride))
                for parameter in values {
                    try storage.charge()
                    guard parameter.id.schema == MOSModelRelease.bsim4_4_5.schemaIdentity,
                          parameter.id.role == role, seen.insert(parameter.id.selector).inserted else {
                        throw BSIM45Error.invalidSchema
                    }
                    let kind: CSBSIM45Kind
                    switch parameter.kind {
                    case .real: kind = CS_BSIM45_REAL
                    case .integer: kind = CS_BSIM45_INTEGER
                    case .flag: kind = CS_BSIM45_FLAG
                    case .text, .vector: throw BSIM45Error.invalidParameter
                    }
                    try Self.check(role == .model
                        ? cs_bsim45_set_model(handle, parameter.id.selector, kind, parameter.value)
                        : cs_bsim45_set_instance(handle, parameter.id.selector, kind, parameter.value))
                }
            }
            if var initial = configuration.initialConditions {
                try withUnsafeBytes(of: &initial) { bytes in
                    try Self.check(cs_bsim45_set_initial_conditions(handle, bytes.bindMemory(to: Double.self).baseAddress!, 3))
                }
            }
            try storage.charge(UInt64(configuration.maximumStressIterations))
            try storage.charge()
            do { try Self.check(cs_bsim45_prepare(handle)) }
            catch let reason as BSIM45Error {
                let (diagnostics, _) = try Self.readDiagnostics(handle, limits: preparationLimits, storage: &storage)
                throw BSIM45PreparationFailure(reason: reason, diagnostics: diagnostics)
            }
            var info = CSBSIM45PreparedInfo()
            try Self.check(cs_bsim45_prepared_info(handle, &info))
            let (diagnostics, diagnosticBytes) = try Self.readDiagnostics(handle, limits: preparationLimits, storage: &storage)
            try preparationControl?.checkCancellation()
            self.topology = .init(nodeCount: Int(info.nodeCount), drainPrime: Int(info.drainPrime), sourcePrime: Int(info.sourcePrime),
                gatePrime: Int(info.gatePrime), gateMid: Int(info.gateMid), bodyPrime: Int(info.bodyPrime), drainBody: Int(info.drainBody),
                sourceBody: Int(info.sourceBody), chargeNode: Int(info.chargeNode), noiseRequested: info.noiseTopology != 0)
            self.diagnostics = diagnostics; self.diagnosticStorageBytes = diagnosticBytes
            self.preparationTemporaryBytes = storage.temporaryBytes; self.preparationWorkUnits = storage.workUnits
            self.state = Mutex(State(handle: handle))
        } catch { cs_bsim45_destroy(handle); throw error }
    }
    deinit { state.withLock { cs_bsim45_destroy($0.handle) } }

    public func evaluate(bias: SIMD16<Double>, analysis: BSIM45Analysis, deficitCoordinate: Double = 0,
                         minimumJunctionConductance: Double = 1e-12) throws -> BSIM45Evaluation {
        var input = bias
        return try state.withLock { owner in
            cs_bsim45_invalidate_trial(owner.handle)
            try validate(input)
            var residual = SIMD16<Double>.zero, rhs = SIMD16<Double>.zero, charge = SIMD16<Double>.zero
            var real = BSIM45Matrix(), imaginary = BSIM45Matrix(), states = SIMD32<Double>.zero
            var token: BSIM45TrialToken?
            switch analysis {
            case .dc:
                guard deficitCoordinate == 0 else { throw BSIM45Error.invalidParameter }
                var out = CSBSIM45StaticResult()
                try withUnsafeBytes(of: &input) { try Self.check(cs_bsim45_evaluate_static(owner.handle,
                    $0.bindMemory(to: Double.self).baseAddress!, 13, minimumJunctionConductance, &out)) }
                residual = Self.vector(out.current, count: 13); charge = Self.vector(out.charge, count: 13)
                real = Self.matrix(out.conductance)
            case .ac(let omega):
                guard deficitCoordinate == 0 else { throw BSIM45Error.invalidParameter }
                var out = CSBSIM45ACResult()
                try withUnsafeBytes(of: &input) { try Self.check(cs_bsim45_evaluate_ac(owner.handle,
                    $0.bindMemory(to: Double.self).baseAddress!, 13, minimumJunctionConductance, omega, &out)) }
                real = Self.matrix(out.real); imaginary = Self.matrix(out.imaginary)
            case .backwardEuler(let dt), .trapezoidal(let dt):
                let method: CSBSIM45IntegrationMethod = if case .backwardEuler = analysis { CS_BSIM45_BE } else { CS_BSIM45_TRAPEZOIDAL }
                var out = CSBSIM45TransientResult()
                try withUnsafeBytes(of: &input) { try Self.check(cs_bsim45_evaluate_transient(owner.handle,
                    $0.bindMemory(to: Double.self).baseAddress!, 13, deficitCoordinate, minimumJunctionConductance, method, dt, &out)) }
                residual = Self.vector(out.residual, count: 13); real = Self.matrix(out.jacobian)
                states = Self.vector(out.states, count: 29)
                token = .init(identity: identity, generation: out.token.generation)
                if topology.chargeNode != 0 { input[topology.chargeNode] = deficitCoordinate }
            }
            for row in 0..<13 {
                rhs[row] = -residual[row]
                for col in 0..<13 { rhs[row] += real[row * 16 + col] * input[col] }
                guard rhs[row].isFinite else { throw BSIM45Error.nonFiniteEvaluation }
            }
            return .init(residual: residual, rhs: rhs, charge: charge, realJacobian: real,
                imaginaryJacobian: imaginary, states: states, token: token)
        }
    }
    public func initializeHistory(at bias: SIMD16<Double>) throws {
        var input = bias
        try state.withLock { owner in
            cs_bsim45_invalidate_trial(owner.handle); try validate(input)
            try withUnsafeBytes(of: &input) { try Self.check(cs_bsim45_initialize_history(owner.handle,
                $0.bindMemory(to: Double.self).baseAddress!, 13, 1e-12)) }
        }
    }
    public func commit(token: BSIM45TrialToken) throws { try finish(token, commit: true) }
    public func reject(token: BSIM45TrialToken) throws { try finish(token, commit: false) }
    private func finish(_ token: BSIM45TrialToken, commit: Bool) throws {
        guard token.identity === identity else { throw BSIM45Error.invalidHistory }
        try state.withLock { owner in
            let native = CSBSIM45TrialToken(owner: UInt(bitPattern: owner.handle), generation: token.generation)
            try Self.check(commit ? cs_bsim45_commit(owner.handle, native) : cs_bsim45_reject(owner.handle, native))
        }
    }
    public func acceptedStates() throws -> SIMD32<Double> {
        try state.withLock { owner in
            var out = CSBSIM45History(); try Self.check(cs_bsim45_history(owner.handle, &out))
            return Self.vector(out.accepted, count: 29)
        }
    }
    public func noiseSpectrum(bias: SIMD16<Double>, frequency: Double, gainReal: SIMD16<Double>,
                              gainImaginary: SIMD16<Double>, minimumJunctionConductance: Double = 1e-12) throws -> BSIM45NoiseSpectrum {
        var input = bias, re = gainReal, im = gainImaginary, out = CSBSIM45NoiseSpectrum()
        try state.withLock { owner in
            cs_bsim45_invalidate_trial(owner.handle); try validate(input); try validate(re); try validate(im)
            try withUnsafeBytes(of: &input) { b in try withUnsafeBytes(of: &re) { r in try withUnsafeBytes(of: &im) { i in
                try Self.check(cs_bsim45_noise_spectrum(owner.handle, b.bindMemory(to: Double.self).baseAddress!, 13,
                    minimumJunctionConductance, frequency, r.bindMemory(to: Double.self).baseAddress!,
                    i.bindMemory(to: Double.self).baseAddress!, &out))
            } } }
        }
        return .init(frequency: frequency, outputSpectralDensities: Self.vector(out.density, count: 14))
    }
    private func validate(_ input: SIMD16<Double>) throws {
        for n in 0..<16 where n == 0 || n > topology.nodeCount || n == topology.chargeNode {
            guard input[n] == 0 else { throw BSIM45Error.invalidParameter }
        }
    }
    private static func readDiagnostics(_ handle: OpaquePointer, limits: MOSPreparationLimits,
                                        storage: inout CompactModelPreparationStorage) throws -> ([BSIM45Diagnostic], UInt64) {
            let count = cs_bsim45_diagnostic_count(handle)
            var textBytes: UInt64 = 0
            for index in 0..<count {
                try storage.charge()
                var value = CSBSIM45Diagnostic()
                try Self.check(cs_bsim45_diagnostic_at(handle, index, &value))
                textBytes += withUnsafeBytes(of: value.text) { UInt64($0.prefix(while: { $0 != 0 }).count) }
            }
            let requested = UInt64(count * MemoryLayout<BSIM45Diagnostic>.stride) + textBytes
            guard requested <= limits.maximumDiagnosticBytes,
                  ownerAllocationBytes + storedPayloadBytes + requested <= limits.maximumRetainedBytes else {
                throw MOSPreparationFailure.capacityExceeded
            }
            var diagnostics: [BSIM45Diagnostic] = []
            diagnostics.reserveCapacity(count)
            let arrayBytes = UInt64(diagnostics.capacity * MemoryLayout<BSIM45Diagnostic>.stride)
            guard arrayBytes + textBytes <= limits.maximumDiagnosticBytes,
                  ownerAllocationBytes + storedPayloadBytes + arrayBytes + textBytes <= limits.maximumRetainedBytes else {
                throw MOSPreparationFailure.capacityExceeded
            }
            var diagnosticBytes = arrayBytes
            for index in 0..<count {
                try storage.charge()
                var value = CSBSIM45Diagnostic()
                try Self.check(cs_bsim45_diagnostic_at(handle, index, &value))
                try storage.check(UInt64(MemoryLayout<CSBSIM45Diagnostic>.stride + 192))
                let text = withUnsafeBytes(of: value.text) { bytes in
                    String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                diagnosticBytes = try CompactModelPreparationStorage.add(diagnosticBytes, UInt64(text.utf8.count))
                guard diagnosticBytes <= limits.maximumDiagnosticBytes,
                      ownerAllocationBytes + storedPayloadBytes + diagnosticBytes <= limits.maximumRetainedBytes else {
                    throw MOSPreparationFailure.capacityExceeded
                }
                diagnostics.append(.init(code: value.code.rawValue, role: value.role.rawValue, parameterID: value.parameterID,
                    sourceSite: value.sourceSite, value: value.value, text: text))
            }
        return (diagnostics, diagnosticBytes)
    }
    private static func check(_ status: CSBSIM45Status) throws {
        if status == CS_BSIM45_OK { return }
        throw switch status {
        case CS_BSIM45_VERSION: BSIM45Error.unsupportedVersion
        case CS_BSIM45_SCHEMA: BSIM45Error.invalidSchema
        case CS_BSIM45_PARAMETER: BSIM45Error.invalidParameter
        case CS_BSIM45_STATE: BSIM45Error.invalidState
        case CS_BSIM45_RESOURCE: BSIM45Error.resourceBudgetExceeded
        case CS_BSIM45_MEMORY: BSIM45Error.allocationFailure
        case CS_BSIM45_DIAGNOSTICS: BSIM45Error.diagnosticCapacityExceeded
        case CS_BSIM45_NONFINITE: BSIM45Error.nonFiniteEvaluation
        case CS_BSIM45_HISTORY: BSIM45Error.invalidHistory
        case CS_BSIM45_NOISE_UNPREPARED: BSIM45Error.noiseNotPrepared
        default: BSIM45Error.kernelRejected
        }
    }
    // Imported fixed Double tuples are initialized contiguous storage. Scoped
    // borrows cannot escape; conversion makes independent bounded SIMD values.
    private static func vector<T, V: SIMD>(_ value: T, count: Int) -> V where V.Scalar == Double {
        withUnsafeBytes(of: value) { bytes in
            let source = bytes.bindMemory(to: Double.self)
            precondition(source.count == count && count <= V.scalarCount)
            var out = V(repeating: 0); for n in 0..<count { out[n] = source[n] }; return out
        }
    }
    private static func matrix<T>(_ value: T) -> BSIM45Matrix {
        withUnsafeBytes(of: value) { bytes in
            let source = bytes.bindMemory(to: Double.self); precondition(source.count == 169)
            var out = BSIM45Matrix()
            for r in 0..<13 { for c in 0..<13 { out.set(r * 16 + c, source[r * 13 + c]) } }; return out
        }
    }
}

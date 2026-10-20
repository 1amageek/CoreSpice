import CoreSpiceAnalysis
import CoreSpiceParsedIR
import Synchronization

/// Retains preparation once and admits only additional result/scratch capacity.
internal final class NativeExecutionStorage: AnalysisResultStorageAccounting {
    struct MaterializationLease: Sendable {
        let owner: NativeExecutionStorage
        let reservation: SPICESourceStorageReservation
    }
    static func nativeOwner(of storage: (any Sendable)?) -> NativeExecutionStorage? {
        if let owner = storage as? NativeExecutionStorage { return owner }
        return (storage as? MaterializationLease)?.owner
    }
    private enum AdmissionFailure: Error { case failedOwner }
    private struct State {
        var scalarCapacity = 0
        var retainedBytes: UInt64 = 0
        var temporaryBytes: UInt64 = 0
        var failed = false
        var reservations: [SPICESourceStorageReservation] = []
    }
    private let preparation: NativeCircuitPreparationRecord
    private let admittedPreparationCapacity: UInt64
    private let state = Mutex(State())

    init(preparation: NativeCircuitPreparationRecord, scalars: Int, retainedBytes: UInt64) throws {
        let copiedReceipts = preparation.osdiLifetime == nil ? 0 : 3 * MemoryLayout<SPICESourceStorageReservation>.stride
        let captureHeader = preparation.constitutiveBacking == nil ? 0 : MemoryLayout<NativeConstitutivePreparationBacking>.stride
        let metadataBytes = try NativeCircuitExecution.capacitySum(UInt64(MemoryLayout<UInt64>.stride),
            NativeCircuitExecution.capacitySum(UInt64(copiedReceipts), UInt64(captureHeader)))
        try Self.validatePeak(preparation: preparation, floor: preparation.compileCapacity,
            retained: metadataBytes, temporary: 0)
        let metadataReservation: SPICESourceStorageReservation
        do { metadataReservation = try Self.reserve(preparation: preparation, kind: .liveOwnedBytes, byteCount: metadataBytes) }
        catch { throw NativeCircuitExecution.resourceFailure(error) }
        admittedPreparationCapacity = preparation.compileCapacity
        self.preparation = try preparation.valueEvidence()
        state.withLock { value in
            value.retainedBytes = metadataBytes
            value.reservations.append(metadataReservation)
        }
        if retainedBytes > 0 {
            try claim(retained: retainedBytes, temporary: 0)
            try retainClaim(retainedBytes)
        }
        try reserveResultScalars(scalars)
    }

    private static func reserve(preparation: NativeCircuitPreparationRecord, kind: SPICESourceStorageKind,
        byteCount: UInt64) throws -> SPICESourceStorageReservation {
        if let control = preparation.constitutiveBacking?.control {
            return try control.reserveNativeStorage(kind: kind, byteCount: byteCount)
        }
        return try preparation.resources.reserveStorage(kind: kind, byteCount: byteCount)
    }

    func reserveResultScalars(_ capacity: Int) throws {
        do { try checkedReserveResultScalars(capacity) }
        catch { state.withLock { $0.failed = true }; throw error }
    }

    private func checkedReserveResultScalars(_ capacity: Int) throws {
        try NativeCircuitExecution.checkResources(preparation)
        let bytes = try state.withLock { value in
            guard !value.failed else { throw AdmissionFailure.failedOwner }
            guard capacity >= 0 else { throw SPICENativeExecutionError.invalidOutput }
            if capacity <= value.scalarCapacity { return UInt64(0) }
            // Covers payload, growth coexistence and later waveform conversion, not RSS.
            let delta = try NativeCircuitExecution.capacityProduct(UInt64(capacity - value.scalarCapacity), 32)
            let next = try NativeCircuitExecution.capacitySum(value.retainedBytes, delta)
            try validatePeak(retained: next, temporary: value.temporaryBytes)
            value.scalarCapacity = capacity
            value.retainedBytes = next
            return delta
        }
        if bytes > 0 { try retainClaim(bytes) }
    }

    private func claim(retained: UInt64, temporary: UInt64) throws {
        try NativeCircuitExecution.checkResources(preparation)
        try state.withLock { value in
            guard !value.failed else { throw AdmissionFailure.failedOwner }
            let nextRetained = try NativeCircuitExecution.capacitySum(value.retainedBytes, retained)
            let nextTemporary = try NativeCircuitExecution.capacitySum(value.temporaryBytes, temporary)
            try validatePeak(retained: nextRetained, temporary: nextTemporary)
            value.retainedBytes = nextRetained
            value.temporaryBytes = nextTemporary
        }
    }

    private func validatePeak(retained: UInt64, temporary: UInt64) throws {
        try Self.validatePeak(preparation: preparation, floor: admittedPreparationCapacity,
            retained: retained, temporary: temporary)
    }

    private static func validatePeak(preparation: NativeCircuitPreparationRecord, floor: UInt64,
                                     retained: UInt64, temporary: UInt64) throws {
        let peak = try NativeCircuitExecution.capacitySum(floor,
            NativeCircuitExecution.capacitySum(retained, temporary))
        guard peak <= preparation.limits.maximumAllocationBytes else {
            guard let requested = Int(exactly: peak), let limit = Int(exactly: preparation.limits.maximumAllocationBytes) else {
                throw SPICENativeExecutionError.resource(TransientExecutionError.arithmeticOverflow("native allocation limit"))
            }
            throw SPICENativeExecutionError.resource(TransientExecutionError.limitExceeded(
                resource: "allocationBytes", limit: limit, requested: requested))
        }
    }

    private func retainClaim(_ bytes: UInt64) throws {
        let reservation: SPICESourceStorageReservation
        do { reservation = try Self.reserve(preparation: preparation, kind: .liveOwnedBytes, byteCount: bytes) }
        catch {
            state.withLock { $0.failed = true; $0.retainedBytes -= bytes }
            throw NativeCircuitExecution.resourceFailure(error)
        }
        try state.withLock { value in
            guard !value.failed else { throw AdmissionFailure.failedOwner }
            value.reservations.append(reservation)
        }
    }

    /// An unpublished materialization can refuse without poisoning completed numerical state.
    func reserveMaterializationBytes(_ byteCount: UInt64) throws -> MaterializationLease {
        try claim(retained: byteCount, temporary: 0)
        let reservation: SPICESourceStorageReservation
        do { reservation = try Self.reserve(preparation: preparation, kind: .liveOwnedBytes, byteCount: byteCount) }
        catch {
            state.withLock { $0.retainedBytes -= byteCount }
            throw NativeCircuitExecution.resourceFailure(error)
        }
        let lease = SPICESourceStorageReservation(kind: .liveOwnedBytes, byteCount: byteCount) { [self, reservation] in
            withExtendedLifetime(reservation) {}
            state.withLock { $0.retainedBytes -= byteCount }
        }
        return MaterializationLease(owner: self, reservation: lease)
    }

    func reserveTemporaryBytes(_ byteCount: UInt64) throws -> any Sendable {
        do { return try checkedReserveTemporaryBytes(byteCount) }
        catch { state.withLock { $0.failed = true }; throw error }
    }

    private func checkedReserveTemporaryBytes(_ byteCount: UInt64) throws -> any Sendable {
        try claim(retained: 0, temporary: byteCount)
        let reservation: SPICESourceStorageReservation
        do { reservation = try Self.reserve(preparation: preparation, kind: .temporaryBytes, byteCount: byteCount) }
        catch {
            state.withLock { $0.failed = true; $0.temporaryBytes -= byteCount }
            throw NativeCircuitExecution.resourceFailure(error)
        }
        return SPICESourceStorageReservation(kind: .temporaryBytes, byteCount: byteCount) { [self, reservation] in
            withExtendedLifetime(reservation) {}
            state.withLock { $0.temporaryBytes -= byteCount }
        }
    }
}

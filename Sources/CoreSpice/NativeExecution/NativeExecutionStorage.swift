import CoreSpiceAnalysis
import CoreSpiceParsedIR
import Synchronization

/// Retains preparation once and admits only additional result/scratch capacity.
internal final class NativeExecutionStorage: AnalysisResultStorageAccounting {
    private enum AdmissionFailure: Error { case failedOwner }
    private struct State {
        var scalarCapacity = 0
        var retainedBytes: UInt64 = 0
        var temporaryBytes: UInt64 = 0
        var failed = false
        var reservations: [SPICESourceStorageReservation] = []
    }
    private let preparation: NativeCircuitPreparationRecord
    private let state = Mutex(State())

    init(preparation: NativeCircuitPreparationRecord, scalars: Int, retainedBytes: UInt64) throws {
        self.preparation = preparation
        if retainedBytes > 0 {
            try claim(retained: retainedBytes, temporary: 0)
            try retainClaim(retainedBytes)
        }
        try reserveResultScalars(scalars)
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
        let peak = try NativeCircuitExecution.capacitySum(preparation.compileCapacity,
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
        do { reservation = try preparation.resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes) }
        catch {
            state.withLock { $0.failed = true; $0.retainedBytes -= bytes }
            throw NativeCircuitExecution.resourceFailure(error)
        }
        try state.withLock { value in
            guard !value.failed else { throw AdmissionFailure.failedOwner }
            value.reservations.append(reservation)
        }
    }

    func reserveTemporaryBytes(_ byteCount: UInt64) throws -> any Sendable {
        do { return try checkedReserveTemporaryBytes(byteCount) }
        catch { state.withLock { $0.failed = true }; throw error }
    }

    private func checkedReserveTemporaryBytes(_ byteCount: UInt64) throws -> any Sendable {
        try claim(retained: 0, temporary: byteCount)
        let reservation: SPICESourceStorageReservation
        do { reservation = try preparation.resources.reserveStorage(kind: .temporaryBytes, byteCount: byteCount) }
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

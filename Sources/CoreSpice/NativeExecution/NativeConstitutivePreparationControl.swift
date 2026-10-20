import CoreSpiceCompile
import CoreSpiceEvent
import CoreSpiceParsedIR
import Synchronization

/// Adds the Native floor condition to the original invocation's actual reservations.
internal final class NativeConstitutivePreparationControl: LinearSolverExecutionControlling {
    enum Failure: Error { case capacityExceeded, busy, sealed, cancelled }
    private struct State {
        var floor: UInt64
        var preparing: UInt64
        var additional: UInt64 = 0
        var pending: Int = 0
        var sealed = false
    }
    private let resources: any SPICESourceResourceAccounting
    private let maximumBytes: UInt64
    private let cancellation: CancellationToken
    private let metadata: SPICESourceStorageReservation
    private let state: Mutex<State>

    static var logicalStateBytes: UInt64 {
        UInt64(MemoryLayout<State>.stride + MemoryLayout<Mutex<State>>.stride
            + MemoryLayout<any SPICESourceResourceAccounting>.stride
            + MemoryLayout<UInt64>.stride + MemoryLayout<CancellationToken>.stride
            + MemoryLayout<SPICESourceStorageReservation>.stride)
    }
    private static var ticketBytes: UInt64 {
        // Logical closure captures; allocator headers and RSS are outside managed payload.
        UInt64(MemoryLayout<(NativeConstitutivePreparationControl, SPICESourceStorageReservation, UInt64, Bool, Bool)>.stride)
    }
    static func make(resources: any SPICESourceResourceAccounting, maximumBytes: UInt64,
        ordinaryFloor: UInt64, cancellation: CancellationToken) throws -> NativeConstitutivePreparationControl {
        guard !cancellation.isCancelled, !Task.isCancelled else { throw Failure.cancelled }
        try resources.checkCancellation()
        guard try Self.sum(ordinaryFloor, Self.logicalStateBytes) <= maximumBytes else { throw Failure.capacityExceeded }
        let metadata = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: Self.logicalStateBytes)
        return NativeConstitutivePreparationControl(resources: resources, maximumBytes: maximumBytes,
            ordinaryFloor: ordinaryFloor, cancellation: cancellation, metadata: metadata)
    }
    private init(resources: any SPICESourceResourceAccounting, maximumBytes: UInt64,
        ordinaryFloor: UInt64, cancellation: CancellationToken, metadata: SPICESourceStorageReservation) {
        self.resources = resources; self.maximumBytes = maximumBytes; self.cancellation = cancellation
        self.metadata = metadata
        state = Mutex(State(floor: ordinaryFloor, preparing: Self.logicalStateBytes))
    }
    private static func sum(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw Failure.capacityExceeded }; return value
    }
    func setPreparingFloor(_ bytes: UInt64) throws {
        try checkpoint(workUnits: 0)
        try state.withLock { value in
            guard !value.sealed else { throw Failure.sealed }
            guard value.pending == 0 else { throw Failure.busy }
            guard try Self.sum(bytes, value.preparing) <= maximumBytes else { throw Failure.capacityExceeded }
            value.floor = bytes
        }
    }
    func seal(retainedOrdinaryFloor: UInt64) throws -> UInt64 {
        try checkpoint(workUnits: 0)
        return try state.withLock { value in
            guard !value.sealed else { throw Failure.sealed }
            guard value.pending == 0 else { throw Failure.busy }
            let total = try Self.sum(retainedOrdinaryFloor, value.preparing)
            guard total <= maximumBytes else { throw Failure.capacityExceeded }
            value.floor = total; value.preparing = 0; value.sealed = true
            return total
        }
    }
    func checkpoint(workUnits: Int) throws {
        guard workUnits >= 0 else { throw Failure.capacityExceeded }
        guard !cancellation.isCancelled, !Task.isCancelled else { throw Failure.cancelled }
        try resources.checkCancellation()
        try resources.charge(.retainedElements, units: UInt64(workUnits))
        guard !cancellation.isCancelled, !Task.isCancelled else { throw Failure.cancelled }
        try resources.checkCancellation()
    }
    func reserveStorage(byteCount: Int) throws -> any Sendable {
        guard byteCount >= 0 else { throw Failure.capacityExceeded }
        return try reserveNativeStorage(kind: .temporaryBytes, byteCount: UInt64(byteCount))
    }
    func reserveNativeStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
        try reserve(kind: kind, byteCount: byteCount, permanent: false).reservation
    }
    func reserveRetainedFloor(byteCount: UInt64, metadataByteCount: UInt64 = 0)
        throws -> (reservation: SPICESourceStorageReservation, capacity: UInt64) {
        try reserve(kind: .liveOwnedBytes, byteCount: byteCount, permanent: true, metadataByteCount: metadataByteCount)
    }
    private func reserve(kind: SPICESourceStorageKind, byteCount: UInt64, permanent: Bool, metadataByteCount: UInt64 = 0)
        throws -> (reservation: SPICESourceStorageReservation, capacity: UInt64) {
        try checkpoint(workUnits: 0)
        let charged = try Self.sum(Self.sum(byteCount, Self.ticketBytes), metadataByteCount)
        let preparing = try state.withLock { value in
            guard !permanent || value.sealed else { throw Failure.busy }
            let current = value.sealed ? value.additional : value.preparing
            let next = try Self.sum(current, charged)
            guard try Self.sum(value.floor, next) <= maximumBytes, value.pending < Int.max else {
                throw Failure.capacityExceeded
            }
            if value.sealed { value.additional = next } else { value.preparing = next }
            value.pending += 1
            return !value.sealed
        }
        let reservation: SPICESourceStorageReservation
        do {
            reservation = try resources.reserveStorage(kind: kind, byteCount: charged)
            try checkpoint(workUnits: 0)
        } catch {
            state.withLock { value in
                if preparing { value.preparing -= charged } else { value.additional -= charged }
                value.pending -= 1
            }
            throw error
        }
        let capacity = state.withLock { value in
            value.pending -= 1
            if permanent {
                // Admission already bounded floor + all pending/additional bytes; moving a
                // successful ticket between those fields cannot overflow or change that peak.
                value.additional -= charged; value.floor += charged
            }
            return value.floor
        }
        let lease = SPICESourceStorageReservation(kind: kind, byteCount: byteCount) { [self, reservation] in
            state.withLock { value in
                if permanent { return }
                if preparing {
                    if !value.sealed { value.preparing -= charged }
                } else { value.additional -= charged }
            }
            withExtendedLifetime(reservation) {}
        }
        return (lease, capacity)
    }
}

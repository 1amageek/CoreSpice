import CoreSpiceParsedIR
import Synchronization

/// A finite shared invocation owner. Receipt release and accounting use the same short memory lock.
public final class SPICESimulationResources: SPICESourceResourceAccounting {
    public enum ResourceError: Error, Sendable { case invalidPolicy, workLimit, hashLimit, storageLimit, cancelled }
    private struct State {
        var live: UInt64 = 0
        var temporary: UInt64 = 0
        var work: UInt64 = 0
        var hashed: UInt64 = 0
    }
    private let state = Mutex(State())
    private let maximumLiveBytes: UInt64
    private let maximumTemporaryBytes: UInt64
    private let maximumWorkUnits: UInt64
    private let maximumHashedBytes: UInt64
    public init(maximumLiveBytes: UInt64, maximumTemporaryBytes: UInt64,
                maximumWorkUnits: UInt64, maximumHashedBytes: UInt64) throws {
        guard maximumLiveBytes > 0, maximumTemporaryBytes > 0,
              maximumWorkUnits > 0, maximumHashedBytes > 0 else { throw ResourceError.invalidPolicy }
        self.maximumLiveBytes = maximumLiveBytes; self.maximumTemporaryBytes = maximumTemporaryBytes
        self.maximumWorkUnits = maximumWorkUnits; self.maximumHashedBytes = maximumHashedBytes
    }
    public func checkCancellation() throws { if Task.isCancelled { throw ResourceError.cancelled } }
    public func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
        try checkCancellation()
        try state.withLock { value in
            guard units <= maximumWorkUnits - value.work else { throw ResourceError.workLimit }
            value.work += units
        }
    }
    public func chargeHashedBytes(_ byteCount: UInt64) throws {
        try checkCancellation()
        try state.withLock { value in
            guard byteCount <= maximumHashedBytes - value.hashed else { throw ResourceError.hashLimit }
            value.hashed += byteCount
        }
    }
    public func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
        try checkCancellation()
        try state.withLock { value in
            switch kind {
            case .liveOwnedBytes:
                guard byteCount <= maximumLiveBytes - value.live else { throw ResourceError.storageLimit }; value.live += byteCount
            case .temporaryBytes:
                guard byteCount <= maximumTemporaryBytes - value.temporary else { throw ResourceError.storageLimit }; value.temporary += byteCount
            }
        }
        return .init(kind: kind, byteCount: byteCount) { [self] in
            state.withLock { value in
                if kind == .liveOwnedBytes { value.live -= byteCount } else { value.temporary -= byteCount }
            }
        }
    }
}

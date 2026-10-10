import CoreSpiceParsedIR
import Synchronization

internal enum SourceBoundaryTestError: Error, Sendable, Equatable {
    case limit(SPICESourceStorageKind), workLimit, hashLimit, cancelled
}

internal final class SourceBoundaryTestResources: SPICESourceResourceAccounting {
    private struct State {
        var live: UInt64 = 0
        var temporary: UInt64 = 0
        var peakLive: UInt64 = 0
        var releases = 0
        var hashed: UInt64 = 0
        var totalWork: UInt64 = 0
        var work: [SPICESourceWorkKind: UInt64] = [:]
        var cancelled = false
        var checksUntilCancellation: Int?
    }
    private let state = Mutex(State())
    private let liveLimit: UInt64
    private let temporaryLimit: UInt64
    private let workLimit: UInt64
    private let hashLimit: UInt64

    init(liveLimit: UInt64 = .max, temporaryLimit: UInt64 = .max,
         workLimit: UInt64 = .max, hashLimit: UInt64 = .max) {
        self.liveLimit = liveLimit; self.temporaryLimit = temporaryLimit
        self.workLimit = workLimit; self.hashLimit = hashLimit
    }

    func checkCancellation() throws {
        let cancelled = state.withLock { value in
            if let remaining = value.checksUntilCancellation {
                value.checksUntilCancellation = remaining - 1
                if remaining <= 1 { value.cancelled = true }
            }
            return value.cancelled
        }
        if Task.isCancelled || cancelled { throw SourceBoundaryTestError.cancelled }
    }
    func setCancelled(_ value: Bool) { state.withLock { $0.cancelled = value } }
    func cancelAfterChecks(_ count: Int) { state.withLock { $0.checksUntilCancellation = count } }
    func used(_ kind: SPICESourceStorageKind) -> UInt64 { state.withLock { kind == .liveOwnedBytes ? $0.live : $0.temporary } }
    var hashedBytes: UInt64 { state.withLock { $0.hashed } }
    var peakLiveBytes: UInt64 { state.withLock { $0.peakLive } }
    var releaseCount: Int { state.withLock { $0.releases } }
    func work(_ kind: SPICESourceWorkKind) -> UInt64 { state.withLock { $0.work[kind, default: 0] } }

    func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
        try checkCancellation()
        try state.withLock { value in
            let (total, overflow) = value.totalWork.addingReportingOverflow(units)
            guard !overflow, total <= workLimit else { throw SourceBoundaryTestError.workLimit }
            value.totalWork = total; value.work[kind, default: 0] += units
        }
    }
    func chargeHashedBytes(_ byteCount: UInt64) throws {
        try checkCancellation()
        try state.withLock { value in
            let (next, overflow) = value.hashed.addingReportingOverflow(byteCount)
            guard !overflow, next <= hashLimit else { throw SourceBoundaryTestError.hashLimit }
            value.hashed = next
        }
    }
    func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
        try checkCancellation()
        try state.withLock { value in
            let current = kind == .liveOwnedBytes ? value.live : value.temporary
            let limit = kind == .liveOwnedBytes ? liveLimit : temporaryLimit
            let (next, overflow) = current.addingReportingOverflow(byteCount)
            guard !overflow, next <= limit else { throw SourceBoundaryTestError.limit(kind) }
            if kind == .liveOwnedBytes { value.live = next; value.peakLive = max(value.peakLive, next) }
            else { value.temporary = next }
        }
        return SPICESourceStorageReservation(kind: kind, byteCount: byteCount) { [self] in
            state.withLock { value in
                if kind == .liveOwnedBytes { value.live -= byteCount } else { value.temporary -= byteCount }
                value.releases += 1
            }
        }
    }
}

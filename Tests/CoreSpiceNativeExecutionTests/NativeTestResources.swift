import CoreSpiceParsedIR
import Synchronization

internal enum SourceBoundaryTestError: Error, Sendable, Equatable {
    case limit(SPICESourceStorageKind), workLimit, hashLimit, cancelled
}

internal final class SourceBoundaryTestResources: SPICESourceResourceAccounting {
    private struct State {
        var live: UInt64 = 0
        var temporary: UInt64 = 0
        var temporaryLimitOverride: UInt64?
        var peakLive: UInt64 = 0
        var peakTemporary: UInt64 = 0
        var reservations = 0
        var releases = 0
        var hashed: UInt64 = 0
        var totalWork: UInt64 = 0
        var work: [SPICESourceWorkKind: UInt64] = [:]
        var cancelled = false
        var checkFailure: SourceBoundaryTestError?
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
        if Task.isCancelled { throw CancellationError() }
        try state.withLock {
            if $0.cancelled { throw CancellationError() }
            if let failure = $0.checkFailure { throw failure }
        }
    }
    func setCheckFailure(_ failure: SourceBoundaryTestError) { state.withLock { $0.checkFailure = failure } }
    func setTemporaryLimit(_ limit: UInt64) { state.withLock { $0.temporaryLimitOverride = limit } }
    func setCancelled(_ value: Bool) { state.withLock { $0.cancelled = value } }
    func used(_ kind: SPICESourceStorageKind) -> UInt64 { state.withLock { kind == .liveOwnedBytes ? $0.live : $0.temporary } }
    var hashedBytes: UInt64 { state.withLock { $0.hashed } }
    var peakLiveBytes: UInt64 { state.withLock { $0.peakLive } }
    var peakTemporaryBytes: UInt64 { state.withLock { $0.peakTemporary } }
    var reservationCount: Int { state.withLock { $0.reservations } }
    func resetTemporaryPeak() { state.withLock { $0.peakTemporary = $0.temporary } }
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
            let limit = kind == .liveOwnedBytes ? liveLimit : value.temporaryLimitOverride ?? temporaryLimit
            let (next, overflow) = current.addingReportingOverflow(byteCount)
            guard !overflow, next <= limit else { throw SourceBoundaryTestError.limit(kind) }
            if kind == .liveOwnedBytes { value.live = next; value.peakLive = max(value.peakLive, next) }
            else { value.temporary = next; value.peakTemporary = max(value.peakTemporary, next) }
            value.reservations += 1
        }
        return SPICESourceStorageReservation(kind: kind, byteCount: byteCount) { [self] in
            state.withLock { value in
                if kind == .liveOwnedBytes { value.live -= byteCount } else { value.temporary -= byteCount }
                value.releases += 1
            }
        }
    }
}

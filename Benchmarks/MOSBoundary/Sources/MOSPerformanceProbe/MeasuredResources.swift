import CoreSpiceIO
import CoreSpiceMOSContracts
import Synchronization

/// Counts admitted capacities and work events, not physical allocator calls.
final class MeasuredResources: SPICESourceResourceAccounting {
    struct Snapshot: Sendable, Codable {
        var liveBytes: UInt64 = 0
        var temporaryBytes: UInt64 = 0
        var peakLiveBytes: UInt64 = 0
        var peakTemporaryBytes: UInt64 = 0
        var peakSimultaneousBytes: UInt64 = 0
        var reservationEvents: UInt64 = 0
        var reservedBytes: UInt64 = 0
        var work: [String: UInt64] = [:]
    }
    private let base: SPICESimulationResources
    private let state = Mutex(Snapshot())
    init() throws {
        base = try SPICESimulationResources(maximumLiveBytes: 128 * 1024 * 1024,
            maximumTemporaryBytes: 64 * 1024 * 1024, maximumWorkUnits: 1_000_000_000,
            maximumHashedBytes: 64 * 1024 * 1024)
    }
    var snapshot: Snapshot { state.withLock { $0 } }
    func checkCancellation() throws { try base.checkCancellation() }
    func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
        try base.charge(kind, units: units)
        state.withLock { $0.work[kind.rawValue, default: 0] += units }
    }
    func chargeHashedBytes(_ byteCount: UInt64) throws { try base.chargeHashedBytes(byteCount) }
    func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
        let admitted = try base.reserveStorage(kind: kind, byteCount: byteCount)
        state.withLock { value in
            if kind == .liveOwnedBytes { value.liveBytes += byteCount } else { value.temporaryBytes += byteCount }
            value.peakLiveBytes = max(value.peakLiveBytes, value.liveBytes)
            value.peakTemporaryBytes = max(value.peakTemporaryBytes, value.temporaryBytes)
            value.peakSimultaneousBytes = max(value.peakSimultaneousBytes, value.liveBytes + value.temporaryBytes)
            value.reservationEvents += 1; value.reservedBytes += byteCount
        }
        return .init(kind: kind, byteCount: byteCount) { [self, admitted] in
            state.withLock { value in
                if kind == .liveOwnedBytes { value.liveBytes -= byteCount } else { value.temporaryBytes -= byteCount }
            }
            withExtendedLifetime(admitted) {}
        }
    }
}


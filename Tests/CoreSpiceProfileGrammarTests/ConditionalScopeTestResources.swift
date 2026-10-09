import CoreSpiceParsedIR
import Synchronization

final class ConditionalScopeTestResources: SPICESourceResourceAccounting {
    let backing = GrammarTestResources()
    private let failingTemporaryReservation: Int
    private let reservations = Mutex(0)

    init(failingTemporaryReservation: Int) {
        self.failingTemporaryReservation = failingTemporaryReservation
    }

    var temporaryReservations: Int { reservations.withLock { $0 } }
    func checkCancellation() throws { try backing.checkCancellation() }
    func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws { try backing.charge(kind, units: units) }
    func chargeHashedBytes(_ byteCount: UInt64) throws { try backing.chargeHashedBytes(byteCount) }

    func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
        if kind == .temporaryBytes {
            let position = reservations.withLock { value in value += 1; return value }
            if position == failingTemporaryReservation {
                if position == 2 { throw GrammarTestError.limit(.temporaryBytes) }
                throw GrammarTestError.cancelled
            }
        }
        return try backing.reserveStorage(kind: kind, byteCount: byteCount)
    }
}

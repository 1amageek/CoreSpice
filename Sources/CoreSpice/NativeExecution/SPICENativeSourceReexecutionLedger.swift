import CoreSpiceParsedIR
import CoreSpiceIO

/// Completed fresh preparations and the reservation backing their ordered metadata.
public struct SPICENativeSourceReexecutionLedger: Sendable {
    public let source: PreparedSPICESimulation
    public let records: [SPICENativeSourceReexecutionCompletion]
    private let reservation: SPICESourceStorageReservation
    internal init(source: PreparedSPICESimulation, records: [SPICENativeSourceReexecutionCompletion], reservation: SPICESourceStorageReservation) {
        self.source = source; self.records = records; self.reservation = reservation
    }
}

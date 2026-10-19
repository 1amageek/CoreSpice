import CoreSpiceOSDI
import CoreSpiceParsedIR

/// Retains the failed cleanup authority and its resource admission for an explicit retry.
public struct SPICEOSDICleanupFailure: Error, Sendable {
    public let primary: any Error
    public let secondary: OSDIAdapterFailure
    internal let lifetime: OSDIExecutionLifetime
    internal let reservations: [SPICESourceStorageReservation]
    internal init(primary: any Error, secondary: OSDIAdapterFailure,
                  lifetime: OSDIExecutionLifetime, reservations: [SPICESourceStorageReservation]) {
        self.primary = primary; self.secondary = secondary; self.lifetime = lifetime; self.reservations = reservations
    }
    public func retryClose() throws(OSDIAdapterFailure) { try lifetime.close() }
}

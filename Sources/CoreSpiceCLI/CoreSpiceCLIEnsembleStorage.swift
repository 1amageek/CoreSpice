import CoreSpiceIO

/// Retains native result capacity and the ensemble run metadata in one invocation.
struct CoreSpiceCLIEnsembleStorage: Sendable {
    let native: (any Sendable)?
    let run: SPICESourceStorageReservation
}

import CoreSpiceAnalysis
import CoreSpiceEvent

/// Closes foreign owners after the entire numerical schedule and session teardown.
internal struct NativeOSDICompletionFinalizer: AnalysisCompletionFinalizing {
    let record: NativeCircuitPreparationRecord
    let cancellation: CancellationToken
    var prior: (any AnalysisCompletionFinalizing)? = nil

    func finalizeCompletion() throws {
        try NativeCircuitExecution.check(cancellation)
        try prior?.finalizeCompletion()
        if let lifetime = record.osdiLifetime {
            do { try lifetime.close() }
            catch { throw SPICENativeExecutionError.osdiCleanup(.init(primary: error, secondary: error,
                lifetime: lifetime, reservations: record.reservations)) }
        }
        try NativeCircuitExecution.check(cancellation)
    }
}

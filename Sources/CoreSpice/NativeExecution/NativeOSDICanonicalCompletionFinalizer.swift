import CoreSpiceAnalysis

/// Rejects an incomplete static-equation promotion before any successful publication.
internal struct NativeOSDICanonicalCompletionFinalizer: AnalysisCompletionFinalizing {
    let validator: NativeOSDICanonicalTransientValidator
    let prior: (any AnalysisCompletionFinalizing)?
    func finalizeCompletion() throws {
        try validator.validateCompletion()
        try prior?.finalizeCompletion()
    }
}

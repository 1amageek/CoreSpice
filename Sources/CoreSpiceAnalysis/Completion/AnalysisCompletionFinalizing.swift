/// Finalizes caller-owned resources after successful numerical validation, before completion publication.
public protocol AnalysisCompletionFinalizing: Sendable {
    func finalizeCompletion() throws
}

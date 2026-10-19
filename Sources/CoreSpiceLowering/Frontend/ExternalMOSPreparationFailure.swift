/// Failures of the explicit source-to-foreign association, not model numerical errors.
public enum ExternalMOSPreparationFailure: Error, Sendable, Equatable {
    case invalidSelection(String)
    case unusedSelection(String)
    case invalidCandidate
    case invalidScalarAddress
    case sourceMismatch
    case invalidFacts
    case parameterFactMismatch(String)
}

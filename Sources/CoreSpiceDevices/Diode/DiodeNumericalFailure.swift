/// Failures of the diode-owned accepted transient history.
public enum DiodeNumericalFailure: Error, Sendable, Equatable {
    case transientSessionRequired
    case transientSessionAlreadyActive
    case invalidIntegration
    case nonfiniteEvaluation
}

/// Binding rejection is distinct from numerical preparation admission.
public enum MOSBindingFailure: Error, Sendable, Equatable {
    case missingPreparedReceipt
    case identityMismatch
    case conditionsMismatch
    case topologyMismatch
    case invalidMatrixMapping
    case terminalInitialConditionsConflict
    case cancelled
}

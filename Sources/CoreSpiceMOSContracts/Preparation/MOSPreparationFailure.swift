/// Preparation admission fails before publishing a receipt or executable owner.
public enum MOSPreparationFailure: Error, Sendable, Equatable {
    case unsupportedInstanceParameter(String)
    case invalidParameter(String)
    case invalidConditions
    case invalidLimits
    case invalidTopology
    case invalidImplementationIdentity
    case invalidReceipt
    case capacityExceeded
    case workLimitExceeded
    case arithmeticOverflow
    case cancelled
    case kernelRejected(String)
}

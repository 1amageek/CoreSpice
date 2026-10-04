/// Kernel failures remain explicit and do not publish a replacement stamp.
public enum BSIM3Error: Error, Sendable, Equatable {
    case unsupportedVersion(String)
    case invalidConfiguration(String)
    case invalidParameter(name: String, model: Bool)
    case modelRejected(String)
    case allocationFailure
    case nonFiniteEvaluation
    case invalidHistory
    case diagnosticCapacityExceeded
}

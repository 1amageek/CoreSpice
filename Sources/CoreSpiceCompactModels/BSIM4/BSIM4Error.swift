public enum BSIM4Error: Error, Sendable, Equatable {
    case unsupportedVersion(String)
    case invalidConfiguration(String)
    case invalidParameter(name: String, model: Bool)
    case modelRejected(String)
    case nonFiniteEvaluation
    case resourceBudgetExceeded
    case allocationFailure
    case diagnosticCapacityExceeded
    case noiseNotPrepared
    case invalidHistory
}

public enum BSIM45Error: Error, Sendable, Equatable {
    case unsupportedVersion, invalidSchema, invalidParameter, invalidState
    case resourceBudgetExceeded, allocationFailure, diagnosticCapacityExceeded
    case kernelRejected, nonFiniteEvaluation, invalidHistory, noiseNotPrepared
}

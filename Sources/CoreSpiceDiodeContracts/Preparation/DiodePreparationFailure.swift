import CoreSpiceEvaluationContracts

public enum DiodePreparationFailure: Error, Sendable, Equatable {
    case schema(DiodeSchemaFailure)
    case invalidConditions
    case invalidLimits
    case invalidEffectiveValue(DiodeModelParameterID)
    case capacityExceeded
    case workLimitExceeded
    case cancelled
    case missingPreparedReceipt
    case identityMismatch
    case conditionsMismatch
    case topologyMismatch
    case invalidMatrixMapping
    case unsupportedAnalysis
    case nonfiniteEvaluation
}

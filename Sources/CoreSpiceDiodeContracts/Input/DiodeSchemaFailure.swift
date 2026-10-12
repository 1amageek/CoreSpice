import CoreSpiceEvaluationContracts

public enum DiodeSchemaFailure: Error, Sendable, Equatable {
    case invalidSelector
    case unsupportedLevel(Double)
    case unsupportedVersionSelector
    case schemaUnavailable(DiodeModelLaw)
    case unknownParameter(name: String, role: DiodeParameterRole)
    case unsupportedParameter(name: String, role: DiodeParameterRole)
    case wrongRole(name: String, requested: DiodeParameterRole)
    case duplicateParameter(DiodeParameterID)
    case invalidParameterName
    case invalidValue(DiodeParameterID)
    case temperature(DiodeParameterID, TemperatureFailure)
    case environmentMismatch
    case conflictingTemperatures
    case invalidScale
    case normalizationOverflow
    case normalizationUnderflow
    case invalidLimits
    case assignmentLimit
    case unsupportedFeature(DiodeFeature)
}

/// Production compact-model composition failures, without losing kernel errors.
public enum BSIM4DeviceError: Error, Sendable, Equatable {
    case missingPreparationPolicy(String)
    case missingModel(String)
    case modelTypeMismatch(String)
    case invalidAuxiliaryTopology(String)
    case transientSessionAlreadyActive(String)
    case transientSessionRequired(String)
    case unsupportedAnalysis(device: String, analysis: String)
}

public enum MOSSchemaFailure: Error, Sendable, Equatable {
    case osdiBindingRequired(level: Int, version: String?)
    case unsupportedRelease(level: Int, version: String?)
    case unknownParameter(name: String, role: MOSParameterRole, release: MOSModelRelease)
    case invalidValue(name: String)
}

public enum MOSSchemaFailure: Error, Sendable, Equatable {
    case unsupportedRelease(level: Int, version: String?)
    case unknownParameter(name: String, role: MOSParameterRole, release: MOSModelRelease)
    case invalidValue(name: String)
    case nonExecutableRelease(MOSModelRelease)
}

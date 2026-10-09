public struct StandardMOSModelSchemas: MOSModelSchemaProviding, Sendable {
    public init() {}
    public func schema(for release: MOSModelRelease) throws(MOSSchemaFailure) -> MOSModelSchema {
        MOSModelSchema(release: release)
    }
}

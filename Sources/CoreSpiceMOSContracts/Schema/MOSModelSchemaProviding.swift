/// Injection supplies schema data; normalization and selection algorithms remain concrete.
public protocol MOSModelSchemaProviding: Sendable {
    func schema(for release: MOSModelRelease) throws(MOSSchemaFailure) -> MOSModelSchema
}

public struct StandardDiodeModelSchemas: DiodeModelSchemaProviding {
    public init() {}
    public func schema(for law: DiodeModelLaw) throws(DiodeSchemaFailure) -> DiodeModelSchema {
        DiodeModelSchema(law: law)
    }
}

public protocol DiodeModelSchemaProviding: Sendable {
    func schema(for law: DiodeModelLaw) throws(DiodeSchemaFailure) -> DiodeModelSchema
}

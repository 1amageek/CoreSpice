/// An original native selector is meaningful only within its exact schema and role.
public struct MOSParameterID: Sendable, Hashable {
    public let schema: MOSSchemaIdentity
    public let role: MOSParameterRole
    public let selector: Int32
    package init(schema: MOSSchemaIdentity, role: MOSParameterRole, selector: Int32) {
        self.schema = schema; self.role = role; self.selector = selector
    }
}

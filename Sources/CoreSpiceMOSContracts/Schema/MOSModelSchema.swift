/// Exact classical input name tables are the sole scaling authority.
public struct MOSModelSchema: Sendable, Hashable {
    public let release: MOSModelRelease
    public var identity: MOSSchemaIdentity { release.schemaIdentity }
    public init(release: MOSModelRelease) { self.release = release }
    public func parameter(named name: String, role: MOSParameterRole) throws(MOSSchemaFailure) -> MOSParameterDefinition {
        let table: [String: MOSSchemaCatalog.Parameter]
        switch (release, role) {
        case (.level1, .model): table = MOSSchemaCatalog.level1Model
        case (.level2, .model): table = MOSSchemaCatalog.level2Model
        case (.level3, .model): table = MOSSchemaCatalog.level3Model
        case (_, .instance): table = MOSSchemaCatalog.simpleInstance
        }
        guard let parameter = table[name] else { throw .unknownParameter(name: name, role: role, release: release) }
        let scaling: MOSParameterScale
        if role == .model { scaling = .none }
        else {
            switch name {
            case "l", "w", "pd", "ps": scaling = .length
            case "ad", "as": scaling = .area
            default: scaling = .none
            }
        }
        return MOSParameterDefinition(name: name, canonicalName: parameter.canonicalName,
            role: role, kind: parameter.kind, scale: scaling)
    }
}

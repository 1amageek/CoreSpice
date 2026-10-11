/// Exact name tables and release-specific setter rules are the sole scaling authority.
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
        case (.level1, .instance), (.level2, .instance), (.level3, .instance): table = MOSSchemaCatalog.simpleInstance
        case (.bsim3_3_3_0, .model): table = MOSSchemaCatalog.bsim3Model
        case (.bsim3_3_3_0, .instance): table = MOSSchemaCatalog.bsim3Instance
        case (.bsim4_4_5, .model): return try bsim45Parameter(named: name, role: role)
        case (.bsim4_4_5, .instance): return try bsim45Parameter(named: name, role: role)
        case (.bsim4_4_8_3, .model): table = MOSSchemaCatalog.bsim483Model
        case (.bsim4_4_8_3, .instance): table = MOSSchemaCatalog.bsim483Instance
        }
        guard let parameter = table[name] else { throw .unknownParameter(name: name, role: role, release: release) }
        let scaling: MOSParameterScale
        if role == .model { scaling = .none }
        else {
            switch name {
            case "l", "w", "pd", "ps": scaling = .length
            case "ad", "as": scaling = .area
            case "sa", "sb", "sd", "sc":
                scaling = release == .bsim4_4_5 || release == .bsim4_4_8_3 ? .length : .none
            default: scaling = .none
            }
        }
        return MOSParameterDefinition(name: name, canonicalName: parameter.canonicalName, role: role, kind: parameter.kind, scale: scaling)
    }
    private func bsim45Parameter(named name: String, role: MOSParameterRole) throws(MOSSchemaFailure) -> MOSParameterDefinition {
        let entry = role == .model ? BSIM45SchemaCatalog.model[name] : BSIM45SchemaCatalog.instance[name == "delvt0" ? "delvto" : name]
        if let entry {
            let scale: MOSParameterScale
            if role == .model { scale = .none } else { scale = switch entry.parameter.canonicalName {
            case "l", "w", "pd", "ps", "sa", "sb", "sd", "sc": .length
            case "ad", "as": .area
            default: .none
            } }
            return MOSParameterDefinition(name: name, canonicalName: entry.parameter.canonicalName,
                role: role, kind: entry.parameter.kind, scale: scale,
                authority: .native(MOSParameterID(schema: identity, role: role, selector: entry.selector)))
        }
        if role == .instance {
            if name == "m" { return .init(name: name, canonicalName: name, role: role, kind: .real, scale: .none, authority: .parallelMultiplicity) }
            let component: Int? = switch name {
            case "ic_vds": 0
            case "ic_vgs": 1
            case "ic_vbs": 2
            default: nil
            }
            if let component {
                return .init(name: name, canonicalName: name, role: role, kind: .real, scale: .none, authority: .initialConditionComponent(component))
            }
        }
        throw .unknownParameter(name: name, role: role, release: release)
    }
}

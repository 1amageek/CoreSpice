public struct MOSParameterDefinition: Sendable, Hashable {
    public let name: String
    public let role: MOSParameterRole
    public let canonicalName: String
    public let kind: MOSParameterKind
    public let scale: MOSParameterScale
    public init(name: String, canonicalName: String, role: MOSParameterRole, kind: MOSParameterKind, scale: MOSParameterScale) {
        self.name = name; self.canonicalName = canonicalName; self.role = role; self.kind = kind; self.scale = scale
    }
    public func validate(_ value: Double) throws(MOSSchemaFailure) {
        guard value.isFinite else { throw .invalidValue(name: name) }
        switch kind {
        case .real: break
        case .integer:
            guard Int32(exactly: value) != nil else { throw .invalidValue(name: name) }
        case .flag:
            guard value == 0 || value == 1 else { throw .invalidValue(name: name) }
        case .text, .vector: throw .invalidValue(name: name)
        }
        if role == .instance {
            switch name {
            case "l", "w", "m":
                guard value > 0 else { throw .invalidValue(name: name) }
            case "ad", "as", "pd", "ps":
                guard value >= 0 else { throw .invalidValue(name: name) }
            default: break
            }
        }
    }
}

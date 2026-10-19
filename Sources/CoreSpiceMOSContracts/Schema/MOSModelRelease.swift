/// Native classical MOS model levels. Compact models require explicit OSDI binding.
public enum MOSModelRelease: String, Sendable, Hashable, CaseIterable {
    case level1, level2, level3

    public var level: Int {
        switch self { case .level1: 1; case .level2: 2; case .level3: 3 }
    }
    public var exactVersion: String? { nil }
    public var schemaIdentity: MOSSchemaIdentity { MOSSchemaIdentity(release: self) }
    public static func resolve(level: Int, version: String?, profile: MOSInputProfile) throws(MOSSchemaFailure) -> MOSModelRelease {
        switch level {
        case 1, 2, 3:
            guard version == nil else { throw .unsupportedRelease(level: level, version: version) }
            return level == 1 ? .level1 : (level == 2 ? .level2 : .level3)
        case 49, 54:
            throw .osdiBindingRequired(level: level, version: version)
        default:
            throw .unsupportedRelease(level: level, version: version)
        }
    }
}

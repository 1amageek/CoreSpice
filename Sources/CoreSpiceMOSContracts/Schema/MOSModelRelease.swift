public enum MOSModelRelease: String, Sendable, Hashable, CaseIterable {
    case level1, level2, level3
    case bsim3_3_3_0
    case bsim4_4_5
    case bsim4_4_8_3

    public var level: Int {
        switch self { case .level1: 1; case .level2: 2; case .level3: 3; case .bsim3_3_3_0: 49; case .bsim4_4_5, .bsim4_4_8_3: 54 }
    }
    public var exactVersion: String? {
        switch self { case .level1, .level2, .level3: nil; case .bsim3_3_3_0: "3.3.0"; case .bsim4_4_5: "4.5.0"; case .bsim4_4_8_3: "4.8.3" }
    }
    public var schemaIdentity: MOSSchemaIdentity { MOSSchemaIdentity(release: self) }
    public static func resolve(level: Int, version: String?, profile: MOSInputProfile) throws(MOSSchemaFailure) -> MOSModelRelease {
        switch level {
        case 1, 2, 3:
            guard version == nil else { throw .unsupportedRelease(level: level, version: version) }
            return level == 1 ? .level1 : (level == 2 ? .level2 : .level3)
        case 49:
            guard version == "3.3.0" else { throw .unsupportedRelease(level: level, version: version) }
            return .bsim3_3_3_0
        case 54:
            switch version {
            case "4.8.3": return .bsim4_4_8_3
            case "4.5", "4.5.0": return .bsim4_4_5
            case "4.500000e+0" where profile == .pinnedNgspiceNormalV1: return .bsim4_4_5
            default: throw .unsupportedRelease(level: level, version: version)
            }
        default: throw .unsupportedRelease(level: level, version: version)
        }
    }
}

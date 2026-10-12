public enum DiodeInputProfile: Sendable, Hashable {
    case coreDiodeV1

    public func modelLaw(level: Double?, version: String?) throws(DiodeSchemaFailure) -> DiodeModelLaw {
        if version != nil { throw .unsupportedVersionSelector }
        if let level {
            guard level.isFinite else { throw .invalidSelector }
            guard level == 1 else { throw .unsupportedLevel(level) }
        }
        return .coreJunctionV1
    }
}

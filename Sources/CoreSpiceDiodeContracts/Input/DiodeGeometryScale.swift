public struct DiodeGeometryScale: Sendable, Hashable {
    public let value: Double
    public init(_ value: Double) throws(DiodeSchemaFailure) {
        guard value.isFinite, value > 0 else { throw .invalidScale }
        self.value = value
    }
}

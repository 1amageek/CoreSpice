/// Unscaled source length; only normalization produces DiodePerimeterMetres.
public struct DiodeInputPerimeter: Sendable, Hashable {
    public let value: Double
    public init(_ value: Double) throws(DiodeSchemaFailure) {
        guard value.isFinite, value >= 0 else { throw .invalidValue(.instance(.perimeter)) }
        self.value = value == 0 ? 0 : value
    }
}

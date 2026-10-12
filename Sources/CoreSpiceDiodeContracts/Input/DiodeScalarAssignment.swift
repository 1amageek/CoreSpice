/// Scalar evaluation occurs upstream; this boundary does not evaluate expressions.
public struct DiodeScalarAssignment: Sendable, Hashable {
    public let name: String
    public let value: Double
    public init(name: String, value: Double) { self.name = name; self.value = value }
}

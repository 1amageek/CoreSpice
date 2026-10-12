public struct DiodeParallelMultiplicity: Sendable, Hashable {
    public let value: Double
    public init(_ value: Double) throws(DiodeSchemaFailure) {
        guard value.isFinite, value > 0 else { throw .invalidValue(.instance(.parallelMultiplicity)) }
        self.value = value
    }
}

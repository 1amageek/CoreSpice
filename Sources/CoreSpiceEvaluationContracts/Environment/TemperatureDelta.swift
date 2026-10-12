public struct TemperatureDelta: Sendable, Hashable {
    public let value: Double

    public init(_ value: Double) throws(TemperatureFailure) {
        guard value.isFinite else { throw .nonFinite }
        self.value = value == 0 ? 0 : value
    }
}

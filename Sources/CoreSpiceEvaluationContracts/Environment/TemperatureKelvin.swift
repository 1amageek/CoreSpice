public struct TemperatureKelvin: Sendable, Hashable {
    public let value: Double

    public init(_ value: Double) throws(TemperatureFailure) {
        guard value.isFinite else { throw .nonFinite }
        guard value > 0 else { throw .absoluteZeroOrBelow }
        self.value = value
    }

    public func celsius() throws(TemperatureFailure) -> TemperatureCelsius {
        let converted = value - 273.15
        guard converted.isFinite, converted > -273.15 else { throw .conversionNotRepresentable }
        return TemperatureCelsius(kelvin: self)
    }

    public func applying(_ delta: TemperatureDelta) throws(TemperatureFailure) -> Self {
        try Self(value + delta.value)
    }
}

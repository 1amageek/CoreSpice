public struct TemperatureCelsius: Sendable, Hashable {
    public let kelvin: TemperatureKelvin
    public var value: Double { kelvin.value - 273.15 }

    init(kelvin: TemperatureKelvin) { self.kelvin = kelvin }

    public init(_ value: Double) throws(TemperatureFailure) {
        guard value.isFinite else { throw .nonFinite }
        guard value > -273.15 else { throw .absoluteZeroOrBelow }
        kelvin = try TemperatureKelvin(value + 273.15)
    }
}

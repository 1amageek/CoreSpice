import Foundation

/// Environment shared by every device bound for one simulation run.
public struct OperatingConditions: Sendable, Hashable {
    public let temperatureKelvin: Double
    public let nominalTemperatureKelvin: Double

    public var temperatureCelsius: Double {
        temperatureKelvin - 273.15
    }

    public init(temperatureKelvin: Double, nominalTemperatureKelvin: Double = 300.15) throws {
        guard temperatureKelvin.isFinite, temperatureKelvin > 0 else {
            throw OperatingConditionsError.invalidTemperatureKelvin(temperatureKelvin)
        }
        guard nominalTemperatureKelvin.isFinite, nominalTemperatureKelvin > 0 else {
            throw OperatingConditionsError.invalidNominalTemperatureKelvin(nominalTemperatureKelvin)
        }
        self.temperatureKelvin = temperatureKelvin
        self.nominalTemperatureKelvin = nominalTemperatureKelvin
    }

    public init(temperatureCelsius: Double, nominalTemperatureCelsius: Double = 27.0) throws {
        guard temperatureCelsius.isFinite else {
            throw OperatingConditionsError.invalidTemperatureCelsius(temperatureCelsius)
        }
        try self.init(temperatureKelvin: temperatureCelsius + 273.15,
            nominalTemperatureKelvin: nominalTemperatureCelsius + 273.15)
    }

    public static let nominal = OperatingConditions(validatedTemperatureKelvin: 300.15)

    private init(validatedTemperatureKelvin: Double) {
        self.temperatureKelvin = validatedTemperatureKelvin
        self.nominalTemperatureKelvin = 300.15
    }
}

public enum OperatingConditionsError: Error, Sendable, Equatable {
    case invalidNominalTemperatureKelvin(Double)
    case invalidTemperatureKelvin(Double)
    case invalidTemperatureCelsius(Double)
}

extension OperatingConditionsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidNominalTemperatureKelvin(let value):
            return "Nominal temperature must be finite and above absolute zero, got \(value) K"
        case .invalidTemperatureKelvin(let value):
            return "Operating temperature must be finite and above absolute zero, got \(value) K"
        case .invalidTemperatureCelsius(let value):
            return "Operating temperature must be finite, got \(value) °C"
        }
    }
}

import Foundation

/// Environment shared by every device bound for one simulation run.
public struct OperatingConditions: Sendable, Hashable {
    public let temperatureKelvin: Double

    public var temperatureCelsius: Double {
        temperatureKelvin - 273.15
    }

    public init(temperatureKelvin: Double) throws {
        guard temperatureKelvin.isFinite, temperatureKelvin > 0 else {
            throw OperatingConditionsError.invalidTemperatureKelvin(temperatureKelvin)
        }
        self.temperatureKelvin = temperatureKelvin
    }

    public init(temperatureCelsius: Double) throws {
        guard temperatureCelsius.isFinite else {
            throw OperatingConditionsError.invalidTemperatureCelsius(temperatureCelsius)
        }
        try self.init(temperatureKelvin: temperatureCelsius + 273.15)
    }

    public static let nominal = OperatingConditions(validatedTemperatureKelvin: 300.15)

    private init(validatedTemperatureKelvin: Double) {
        self.temperatureKelvin = validatedTemperatureKelvin
    }
}

public enum OperatingConditionsError: Error, Sendable, Equatable {
    case invalidTemperatureKelvin(Double)
    case invalidTemperatureCelsius(Double)
}

extension OperatingConditionsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidTemperatureKelvin(let value):
            return "Operating temperature must be finite and above absolute zero, got \(value) K"
        case .invalidTemperatureCelsius(let value):
            return "Operating temperature must be finite, got \(value) °C"
        }
    }
}

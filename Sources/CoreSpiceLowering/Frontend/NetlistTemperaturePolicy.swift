import CoreSpiceEvaluationContracts

/// Explicit checked fallback conditions and caller overrides for source evaluation.
public struct NetlistTemperaturePolicy: Sendable {
    public let defaults: EvaluationEnvironment
    public let ambientOverride: TemperatureKelvin?
    public let nominalOverride: TemperatureKelvin?

    public init(defaults: EvaluationEnvironment, ambientOverride: TemperatureKelvin? = nil,
                nominalOverride: TemperatureKelvin? = nil) {
        self.defaults = defaults; self.ambientOverride = ambientOverride; self.nominalOverride = nominalOverride
    }
    /// The documented source-evaluation convenience policy, independent of process settings.
    public static var standard: Self {
        get throws(TemperatureFailure) {
            let temperature = try TemperatureCelsius(27).kelvin
            return .init(defaults: .init(ambient: temperature, nominal: temperature))
        }
    }
}

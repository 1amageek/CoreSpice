/// Immutable values admitted for a memoryless semiconductor resistor.
struct StaticResistorParameters: Sendable {
    let conductance: Double
    let acConductance: Double
    let noiseTemperatureKelvin: Double
    let multiplier: Double
    let noisy: Bool
    let flickerCoefficient: Double
    let flickerCurrentExponent: Double
    let flickerFrequencyExponent: Double
    let effectiveNoiseArea: Double
}

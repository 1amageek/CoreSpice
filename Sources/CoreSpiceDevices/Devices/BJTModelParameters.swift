import Foundation

/// Polarity of a bipolar junction transistor.
public enum BJTPolarity: Sendable {
    case npn
    case pnp
}

/// Model parameters for a Bipolar Junction Transistor (BJT).
///
/// These parameters follow the SPICE Ebers-Moll model conventions.
/// The model supports both NPN and PNP transistors and includes
/// Early effect modeling.
public struct BJTModelParameters: Sendable {

    /// Transistor polarity (NPN or PNP).
    public var polarity: BJTPolarity

    /// Transport saturation current (A). Default: 1e-16 A.
    public var saturationCurrent: Double

    /// Ideal maximum forward beta. Default: 100.
    public var forwardBeta: Double

    /// Ideal maximum reverse beta. Default: 1.
    public var reverseBeta: Double

    /// Forward current emission coefficient. Default: 1.0.
    public var forwardEmissionCoefficient: Double

    /// Reverse current emission coefficient. Default: 1.0.
    public var reverseEmissionCoefficient: Double

    /// Forward Early voltage (V). Default: infinity (no Early effect).
    public var forwardEarlyVoltage: Double

    /// Reverse Early voltage (V). Default: infinity.
    public var reverseEarlyVoltage: Double

    /// Base ohmic resistance (Ω). Default: 0.
    public var baseResistance: Double

    /// Collector ohmic resistance (Ω). Default: 0.
    public var collectorResistance: Double

    /// Emitter ohmic resistance (Ω). Default: 0.
    public var emitterResistance: Double

    /// Base-emitter zero-bias depletion capacitance (F). Default: 0.
    public var baseEmitterCapacitance: Double

    /// Base-collector zero-bias depletion capacitance (F). Default: 0.
    public var baseCollectorCapacitance: Double

    /// Ideal forward transit time (s). Default: 0.
    public var forwardTransitTime: Double

    /// Ideal reverse transit time (s). Default: 0.
    public var reverseTransitTime: Double

    /// Base-emitter junction potential (V). Default: 0.75 V.
    public var baseEmitterPotential: Double

    /// Base-collector junction potential (V). Default: 0.75 V.
    public var baseCollectorPotential: Double

    /// Base-emitter grading coefficient. Default: 0.33.
    public var baseEmitterGradingCoeff: Double

    /// Base-collector grading coefficient. Default: 0.33.
    public var baseCollectorGradingCoeff: Double

    /// Nominal temperature (K). Default: 300.15 K.
    public var nominalTemperature: Double

    /// Creates default BJT parameters for an NPN transistor.
    public init(
        polarity: BJTPolarity = .npn,
        saturationCurrent: Double = 1e-16,
        forwardBeta: Double = 100,
        reverseBeta: Double = 1,
        forwardEmissionCoefficient: Double = 1.0,
        reverseEmissionCoefficient: Double = 1.0,
        forwardEarlyVoltage: Double = .infinity,
        reverseEarlyVoltage: Double = .infinity,
        baseResistance: Double = 0,
        collectorResistance: Double = 0,
        emitterResistance: Double = 0,
        baseEmitterCapacitance: Double = 0,
        baseCollectorCapacitance: Double = 0,
        forwardTransitTime: Double = 0,
        reverseTransitTime: Double = 0,
        baseEmitterPotential: Double = 0.75,
        baseCollectorPotential: Double = 0.75,
        baseEmitterGradingCoeff: Double = 0.33,
        baseCollectorGradingCoeff: Double = 0.33,
        nominalTemperature: Double = 300.15
    ) {
        self.polarity = polarity
        self.saturationCurrent = saturationCurrent
        self.forwardBeta = forwardBeta
        self.reverseBeta = reverseBeta
        self.forwardEmissionCoefficient = forwardEmissionCoefficient
        self.reverseEmissionCoefficient = reverseEmissionCoefficient
        self.forwardEarlyVoltage = forwardEarlyVoltage
        self.reverseEarlyVoltage = reverseEarlyVoltage
        self.baseResistance = baseResistance
        self.collectorResistance = collectorResistance
        self.emitterResistance = emitterResistance
        self.baseEmitterCapacitance = baseEmitterCapacitance
        self.baseCollectorCapacitance = baseCollectorCapacitance
        self.forwardTransitTime = forwardTransitTime
        self.reverseTransitTime = reverseTransitTime
        self.baseEmitterPotential = baseEmitterPotential
        self.baseCollectorPotential = baseCollectorPotential
        self.baseEmitterGradingCoeff = baseEmitterGradingCoeff
        self.baseCollectorGradingCoeff = baseCollectorGradingCoeff
        self.nominalTemperature = nominalTemperature
    }

    /// Thermal voltage at nominal temperature (kT/q).
    public var thermalVoltage: Double {
        let k = 1.380649e-23  // Boltzmann constant (J/K)
        let q = 1.602176634e-19  // Elementary charge (C)
        return k * nominalTemperature / q
    }

    /// Forward alpha (common-base current gain).
    public var forwardAlpha: Double {
        forwardBeta / (forwardBeta + 1)
    }

    /// Reverse alpha (common-base current gain).
    public var reverseAlpha: Double {
        reverseBeta / (reverseBeta + 1)
    }

    public func validate(device: String) throws {
        try requirePositive(saturationCurrent, "is", device: device)
        try requirePositive(forwardBeta, "bf", device: device)
        try requirePositive(reverseBeta, "br", device: device)
        try requirePositive(forwardEmissionCoefficient, "nf", device: device)
        try requirePositive(reverseEmissionCoefficient, "nr", device: device)
        try requirePositive(forwardEarlyVoltage, "vaf", device: device)
        try requirePositive(reverseEarlyVoltage, "var", device: device)
        try requireNonNegative(baseResistance, "rb", device: device)
        try requireNonNegative(collectorResistance, "rc", device: device)
        try requireNonNegative(emitterResistance, "re", device: device)
        try requireNonNegative(baseEmitterCapacitance, "cje", device: device)
        try requireNonNegative(baseCollectorCapacitance, "cjc", device: device)
        try requireNonNegative(forwardTransitTime, "tf", device: device)
        try requireNonNegative(reverseTransitTime, "tr", device: device)
        try requirePositive(baseEmitterPotential, "vje", device: device)
        try requirePositive(baseCollectorPotential, "vjc", device: device)
        try requireGrading(baseEmitterGradingCoeff, "mje", device: device)
        try requireGrading(baseCollectorGradingCoeff, "mjc", device: device)
        try requirePositive(nominalTemperature, "tnom", device: device)
    }

    private func requireFinite(_ value: Double, _ parameter: String, device: String) throws {
        guard value.isFinite else {
            throw DeviceBindingError.invalidParameterValue(
                device: device,
                parameter: parameter,
                message: "Parameter must be finite"
            )
        }
    }

    private func requirePositive(_ value: Double, _ parameter: String, device: String) throws {
        try requireFinite(value, parameter, device: device)
        guard value > 0 else {
            throw DeviceBindingError.invalidParameterValue(
                device: device,
                parameter: parameter,
                message: "Parameter must be positive"
            )
        }
    }

    private func requireNonNegative(_ value: Double, _ parameter: String, device: String) throws {
        try requireFinite(value, parameter, device: device)
        guard value >= 0 else {
            throw DeviceBindingError.invalidParameterValue(
                device: device,
                parameter: parameter,
                message: "Parameter must be non-negative"
            )
        }
    }

    private func requireGrading(_ value: Double, _ parameter: String, device: String) throws {
        try requireFinite(value, parameter, device: device)
        guard value >= 0 && value < 1 else {
            throw DeviceBindingError.invalidParameterValue(
                device: device,
                parameter: parameter,
                message: "Junction grading coefficient must be in [0, 1)"
            )
        }
    }
}

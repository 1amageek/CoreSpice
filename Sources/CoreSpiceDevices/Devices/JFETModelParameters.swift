import Foundation

/// Polarity of a junction field-effect transistor.
public enum JFETPolarity: Sendable {
    case nChannel
    case pChannel
}

/// Model parameters for a Shichman-Hodges JFET.
///
/// The channel current follows the same region structure as the SPICE level-1
/// JFET model. Gate-source and gate-drain junctions use Shockley leakage so
/// forward-biased gate operation is represented instead of acting as an ideal
/// open circuit.
public struct JFETModelParameters: Sendable {

    /// Device polarity.
    public var polarity: JFETPolarity

    /// Threshold/pinch-off voltage (V). SPICE NJF and PJF models both use negative depletion defaults.
    public var thresholdVoltage: Double

    /// Transconductance coefficient (A/V^2).
    public var beta: Double

    /// Channel-length modulation coefficient (1/V).
    public var lambda: Double

    /// Gate junction saturation current (A).
    public var saturationCurrent: Double

    /// Gate junction emission coefficient.
    public var emissionCoefficient: Double

    /// Linear gate-source capacitance (F).
    public var gateSourceCapacitance: Double

    /// Linear gate-drain capacitance (F).
    public var gateDrainCapacitance: Double

    /// Gate junction built-in potential (V).
    public var gateJunctionPotential: Double

    /// Gate junction grading coefficient.
    public var gateJunctionGradingCoefficient: Double

    /// Forward-bias depletion capacitance coefficient.
    public var forwardBiasDepletionCoefficient: Double

    /// Flicker noise coefficient.
    public var flickerNoiseCoefficient: Double

    /// Flicker noise current exponent.
    public var flickerNoiseExponent: Double

    /// Instance area multiplier.
    public var area: Double

    /// Nominal temperature (K).
    public var nominalTemperature: Double

    /// Circuit operating temperature (K).
    public var operatingTemperature: Double

    public init(
        polarity: JFETPolarity = .nChannel,
        thresholdVoltage: Double? = nil,
        beta: Double = 1e-4,
        lambda: Double = 0.0,
        saturationCurrent: Double = 1e-14,
        emissionCoefficient: Double = 1.0,
        gateSourceCapacitance: Double = 0.0,
        gateDrainCapacitance: Double = 0.0,
        gateJunctionPotential: Double = 1.0,
        gateJunctionGradingCoefficient: Double = 0.5,
        forwardBiasDepletionCoefficient: Double = 0.5,
        flickerNoiseCoefficient: Double = 0.0,
        flickerNoiseExponent: Double = 1.0,
        area: Double = 1.0,
        nominalTemperature: Double = 300.15,
        operatingTemperature: Double? = nil
    ) {
        self.polarity = polarity
        self.thresholdVoltage = thresholdVoltage ?? -2.0
        self.beta = beta
        self.lambda = lambda
        self.saturationCurrent = saturationCurrent
        self.emissionCoefficient = emissionCoefficient
        self.gateSourceCapacitance = gateSourceCapacitance
        self.gateDrainCapacitance = gateDrainCapacitance
        self.gateJunctionPotential = gateJunctionPotential
        self.gateJunctionGradingCoefficient = gateJunctionGradingCoefficient
        self.forwardBiasDepletionCoefficient = forwardBiasDepletionCoefficient
        self.flickerNoiseCoefficient = flickerNoiseCoefficient
        self.flickerNoiseExponent = flickerNoiseExponent
        self.area = area
        self.nominalTemperature = nominalTemperature
        self.operatingTemperature = operatingTemperature ?? nominalTemperature
    }

    /// Thermal voltage at the circuit operating temperature (kT/q).
    public var thermalVoltage: Double {
        let k = 1.380649e-23
        let q = 1.602176634e-19
        return k * operatingTemperature / q
    }

    var channelSign: Double {
        polarity == .nChannel ? 1.0 : -1.0
    }

    var normalizedThresholdVoltage: Double {
        thresholdVoltage
    }

    var effectiveBeta: Double {
        beta * area
    }

    var effectiveSaturationCurrent: Double {
        saturationCurrent * area
    }

    var effectiveGateSourceCapacitance: Double {
        gateSourceCapacitance * area
    }

    var effectiveGateDrainCapacitance: Double {
        gateDrainCapacitance * area
    }

    public func validate(device: String) throws {
        try requireFinite(thresholdVoltage, "vto", device: device)
        try requirePositive(beta, "beta", device: device)
        try requireNonNegative(lambda, "lambda", device: device)
        try requirePositive(saturationCurrent, "is", device: device)
        try requirePositive(emissionCoefficient, "n", device: device)
        try requireNonNegative(gateSourceCapacitance, "cgs", device: device)
        try requireNonNegative(gateDrainCapacitance, "cgd", device: device)
        try requirePositive(gateJunctionPotential, "pb", device: device)
        try requireGrading(gateJunctionGradingCoefficient, "m", device: device)
        try requireForwardCoefficient(forwardBiasDepletionCoefficient, "fc", device: device)
        try requireNonNegative(flickerNoiseCoefficient, "kf", device: device)
        try requirePositive(flickerNoiseExponent, "af", device: device)
        try requirePositive(area, "area", device: device)
        try requirePositive(nominalTemperature, "tnom", device: device)
        try requirePositive(operatingTemperature, "temp", device: device)
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

    private func requireForwardCoefficient(_ value: Double, _ parameter: String, device: String) throws {
        try requireFinite(value, parameter, device: device)
        guard value >= 0 && value < 1 else {
            throw DeviceBindingError.invalidParameterValue(
                device: device,
                parameter: parameter,
                message: "Forward-bias depletion coefficient must be in [0, 1)"
            )
        }
    }
}

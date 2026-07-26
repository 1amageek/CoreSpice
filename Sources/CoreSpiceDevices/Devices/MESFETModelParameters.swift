import Foundation

/// Parameters for the SPICE Curtice MESFET model.
public struct MESFETModelParameters: Sendable {
    public var polarity: MESFETPolarity
    public var thresholdVoltage: Double
    public var alpha: Double
    public var beta: Double
    public var lambda: Double
    public var dopingTailParameter: Double
    public var saturationCurrent: Double
    public var gateSourceCapacitance: Double
    public var gateDrainCapacitance: Double
    public var gateJunctionPotential: Double
    public var forwardBiasDepletionCoefficient: Double
    public var flickerNoiseCoefficient: Double
    public var flickerNoiseExponent: Double
    public var area: Double
    public var multiplier: Double
    public var nominalTemperature: Double
    public var operatingTemperature: Double

    public init(
        polarity: MESFETPolarity = .nChannel,
        thresholdVoltage: Double = -2,
        alpha: Double = 2,
        beta: Double = 2.5e-3,
        lambda: Double = 0,
        dopingTailParameter: Double = 0.3,
        saturationCurrent: Double = 1e-14,
        gateSourceCapacitance: Double = 0,
        gateDrainCapacitance: Double = 0,
        gateJunctionPotential: Double = 1,
        forwardBiasDepletionCoefficient: Double = 0.5,
        flickerNoiseCoefficient: Double = 0,
        flickerNoiseExponent: Double = 1,
        area: Double = 1,
        multiplier: Double = 1,
        nominalTemperature: Double = 300.15,
        operatingTemperature: Double? = nil
    ) {
        self.polarity = polarity
        self.thresholdVoltage = thresholdVoltage
        self.alpha = alpha
        self.beta = beta
        self.lambda = lambda
        self.dopingTailParameter = dopingTailParameter
        self.saturationCurrent = saturationCurrent
        self.gateSourceCapacitance = gateSourceCapacitance
        self.gateDrainCapacitance = gateDrainCapacitance
        self.gateJunctionPotential = gateJunctionPotential
        self.forwardBiasDepletionCoefficient = forwardBiasDepletionCoefficient
        self.flickerNoiseCoefficient = flickerNoiseCoefficient
        self.flickerNoiseExponent = flickerNoiseExponent
        self.area = area
        self.multiplier = multiplier
        self.nominalTemperature = nominalTemperature
        self.operatingTemperature = operatingTemperature ?? nominalTemperature
    }

    var channelSign: Double {
        polarity == .nChannel ? 1 : -1
    }

    var scale: Double {
        area * multiplier
    }

    var effectiveBeta: Double {
        beta * scale
    }

    var effectiveSaturationCurrent: Double {
        saturationCurrent * scale
    }

    var effectiveGateSourceCapacitance: Double {
        gateSourceCapacitance * scale
    }

    var effectiveGateDrainCapacitance: Double {
        gateDrainCapacitance * scale
    }

    var thermalVoltage: Double {
        let boltzmann = 1.380649e-23
        let electronCharge = 1.602176634e-19
        return boltzmann * operatingTemperature / electronCharge
    }

    public func validate(device: String) throws {
        try requireFinite(thresholdVoltage, "vto", device: device)
        try requirePositive(alpha, "alpha", device: device)
        try requirePositive(beta, "beta", device: device)
        try requireNonNegative(lambda, "lambda", device: device)
        try requireNonNegative(dopingTailParameter, "b", device: device)
        try requirePositive(saturationCurrent, "is", device: device)
        try requireNonNegative(gateSourceCapacitance, "cgs", device: device)
        try requireNonNegative(gateDrainCapacitance, "cgd", device: device)
        try requireGatePotential(gateJunctionPotential, device: device)
        try requireUnitInterval(forwardBiasDepletionCoefficient, "fc", device: device)
        try requireNonNegative(flickerNoiseCoefficient, "kf", device: device)
        try requirePositive(flickerNoiseExponent, "af", device: device)
        try requirePositive(area, "area", device: device)
        try requirePositive(multiplier, "m", device: device)
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

    private func requireUnitInterval(_ value: Double, _ parameter: String, device: String) throws {
        try requireFinite(value, parameter, device: device)
        guard value >= 0, value < 1 else {
            throw DeviceBindingError.invalidParameterValue(
                device: device,
                parameter: parameter,
                message: "Parameter must be in [0, 1)"
            )
        }
    }

    private func requireGatePotential(_ value: Double, device: String) throws {
        try requireFinite(value, "pb", device: device)
        guard value > 0.5 else {
            throw DeviceBindingError.invalidParameterValue(
                device: device,
                parameter: "pb",
                message: "Parameter must be greater than 0.5 V for Curtice gate-charge evaluation"
            )
        }
    }
}

import Foundation

/// The common Level 3 channel law in polarity-normalized terminal coordinates.
/// All derivatives describe `current`, including the parallel numerical leakage.
struct MOSL3Channel {
    let current: Double
    let gateDerivative: Double
    let drainDerivative: Double
    let bodyDerivative: Double

    static let stabilizationConductance = 1e-12
    private static let smoothingVoltage = 0.025
    private static let bodyPotentialFloor = 0.01

    static func validate(_ parameters: MOSFETModelParameters, device: String) throws {
        try parameters.validate(device: device)
        for (name, value) in [("theta", parameters.theta), ("kappa", parameters.kappa)] {
            guard value >= 0 else {
                throw DeviceBindingError.invalidParameterValue(
                    device: device, parameter: name,
                    message: "Level 3 denominator coefficient must be non-negative"
                )
            }
        }
        let velocity = velocityCoefficient(parameters)
        for (name, value) in [("beta", parameters.beta), ("cox", parameters.cox),
                              ("velocityCoefficient", velocity),
                              ("effectiveVelocityCoefficient", parameters.kappa + velocity)] {
            guard value.isFinite else {
                throw DeviceBindingError.invalidParameterValue(
                    device: device, parameter: name,
                    message: "Derived Level 3 coefficient must be finite"
                )
            }
        }
    }

    static func velocityCoefficient(_ parameters: MOSFETModelParameters) -> Double {
        guard parameters.vmax > 0, parameters.cox > 0 else { return 0 }
        return (parameters.kp / parameters.cox) / (parameters.vmax * parameters.l)
    }

    static func threshold(_ parameters: MOSFETModelParameters, polarity: Double,
                          drainBias: Double, bodyBias: Double) -> Double {
        polarity * parameters.vto
            + parameters.gamma * (sqrt(max(parameters.phi - bodyBias, bodyPotentialFloor))
                                    - sqrt(parameters.phi))
            - parameters.eta * drainBias
    }

    static func saturationBias(_ parameters: MOSFETModelParameters, overdrive: Double) -> Double {
        overdrive / (1 + (parameters.kappa + velocityCoefficient(parameters)) * overdrive)
    }

    init(parameters p: MOSFETModelParameters, polarity: Double,
         gateBias: Double, drainBias: Double, bodyBias: Double) {
        let rawOverdrive = gateBias - Self.threshold(p, polarity: polarity,
                                                     drainBias: drainBias, bodyBias: bodyBias)
        let magnitude = hypot(rawOverdrive, Self.smoothingVoltage)
        // The negative branch avoids cancellation; hypot avoids squaring overflow.
        let overdrive = rawOverdrive < 0
            ? (Self.smoothingVoltage * Self.smoothingVoltage / magnitude)
                / (2 * (1 - rawOverdrive / magnitude))
            : 0.5 * rawOverdrive + 0.5 * magnitude
        let overdriveDerivative = overdrive / magnitude
        let mobilityDenominator = 1 + p.theta * overdrive
        let beta = p.beta / mobilityDenominator
        let betaDerivative = -beta * p.theta / mobilityDenominator
        let saturationDenominator = 1 + (p.kappa + Self.velocityCoefficient(p)) * overdrive
        let saturation = overdrive / saturationDenominator
        let saturationDerivative = (1 / saturationDenominator) / saturationDenominator
        let lengthModulation = 1 + p.lambda * drainBias
        let shape: Double
        let shapeDerivative: Double
        let directDrainDerivative: Double
        if drainBias < saturation {
            shape = drainBias * (overdrive - 0.5 * drainBias)
            shapeDerivative = drainBias
            directDrainDerivative = beta * (overdrive - drainBias) * lengthModulation
        } else {
            shape = saturation * (overdrive - 0.5 * saturation)
            shapeDerivative = saturation + (overdrive - saturation) * saturationDerivative
            directDrainDerivative = 0
        }
        let gateDerivative = (betaDerivative * shape + beta * shapeDerivative)
            * overdriveDerivative * lengthModulation
        let bodyPotential = p.phi - bodyBias
        let bodyDerivative = bodyPotential > Self.bodyPotentialFloor
            ? gateDerivative * p.gamma / (2 * sqrt(bodyPotential)) : 0
        self.current = beta * shape * lengthModulation
            + Self.stabilizationConductance * drainBias
        self.gateDerivative = gateDerivative
        self.drainDerivative = directDrainDerivative + gateDerivative * p.eta
            + beta * shape * p.lambda + Self.stabilizationConductance
        self.bodyDerivative = bodyDerivative
    }
}

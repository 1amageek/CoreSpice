import Foundation

/// Intrinsic normalized SPICE3 low-injection current and stored-charge evaluation.
struct BJTModelEvaluation: Sendable {
    struct Quantity: Sendable {
        let value: Double
        let be: Double
        let bc: Double
    }
    let collector: Quantity
    let base: Quantity
    let emitter: Quantity
    let beCharge: Quantity
    let bcCharge: Quantity

    init(parameters p: BJTModelParameters, be: Double, bc: Double, device: String) throws {
        let forward = Self.junction(be, saturation: p.saturationCurrent,
            thermal: p.forwardEmissionCoefficient * p.thermalVoltage)
        let reverse = Self.junction(bc, saturation: p.saturationCurrent,
            thermal: p.reverseEmissionCoefficient * p.thermalVoltage)
        let invForward = 1 / p.forwardEarlyVoltage, invReverse = 1 / p.reverseEarlyVoltage
        let width = 1 - bc * invForward - be * invReverse
        guard width.isFinite, width > 0 else {
            throw DeviceBindingError.invalidParameterValue(device: device,
                parameter: "baseWidth", message: "Intrinsic Early base-width factor must be finite and positive")
        }
        let transport = (forward.0 - reverse.0) * width
        let transportBE = forward.1 * width - (forward.0 - reverse.0) * invReverse
        let transportBC = -reverse.1 * width - (forward.0 - reverse.0) * invForward
        collector = Quantity(value: transport - reverse.0 / p.reverseBeta,
            be: transportBE, bc: transportBC - reverse.1 / p.reverseBeta)
        base = Quantity(value: forward.0 / p.forwardBeta + reverse.0 / p.reverseBeta,
            be: forward.1 / p.forwardBeta, bc: reverse.1 / p.reverseBeta)
        emitter = Quantity(value: -collector.value - base.value,
            be: -collector.be - base.be, bc: -collector.bc - base.bc)
        let depletionBE = Self.depletion(be, capacitance: p.baseEmitterCapacitance,
            potential: p.baseEmitterPotential, grading: p.baseEmitterGradingCoeff)
        let depletionBC = Self.depletion(bc, capacitance: p.baseCollectorCapacitance,
            potential: p.baseCollectorPotential, grading: p.baseCollectorGradingCoeff)
        // The pinned SPICE3 reference normalizes forward diffusion by qb only for positive Vbe.
        let diffusion = be > 0 ? forward.0 * width : forward.0
        let diffusionBE = be > 0 ? forward.1 * width - forward.0 * invReverse : forward.1
        let diffusionBC = be > 0 ? -forward.0 * invForward : 0
        beCharge = Quantity(value: depletionBE.0 + p.forwardTransitTime * diffusion,
            be: depletionBE.1 + p.forwardTransitTime * diffusionBE,
            bc: p.forwardTransitTime * diffusionBC)
        bcCharge = Quantity(value: depletionBC.0 + p.reverseTransitTime * reverse.0,
            be: 0, bc: depletionBC.1 + p.reverseTransitTime * reverse.1)
        func finite(_ q: Quantity) -> Bool {
            q.value.isFinite && q.be.isFinite && q.bc.isFinite && (q.be + q.bc).isFinite
        }
        guard be.isFinite, bc.isFinite, finite(collector), finite(base), finite(emitter),
              finite(beCharge), finite(bcCharge) else {
            throw DeviceBindingError.invalidParameterValue(device: device,
                parameter: "operatingPoint", message: "BJT current, charge and derivatives must be finite")
        }
    }

    private static func junction(_ voltage: Double, saturation: Double, thermal: Double) -> (Double, Double) {
        if voltage >= -3 * thermal {
            let exponential = exp(voltage / thermal)
            return (saturation * expm1(voltage / thermal), saturation * exponential / thermal)
        }
        let ratio = 3 * thermal / (voltage * exp(1.0))
        let cube = ratio * ratio * ratio
        return (-saturation * (1 + cube), saturation * 3 * cube / voltage)
    }

    private static func depletion(_ voltage: Double, capacitance: Double,
        potential: Double, grading: Double) -> (Double, Double) {
        guard capacitance > 0 else { return (0, 0) }
        let half = 0.5 * potential
        if voltage < half {
            let logarithm = log1p(-voltage / potential)
            let charge = -potential * capacitance * expm1((1 - grading) * logarithm) / (1 - grading)
            return (charge, capacitance * exp(-grading * logarithm))
        }
        let atHalf = potential * capacitance * (1 - pow(0.5, 1 - grading)) / (1 - grading)
        let capHalf = capacitance / pow(0.5, grading)
        let slope = 2 * grading * capHalf / potential
        let delta = voltage - half
        return (atHalf + capHalf * delta + 0.5 * slope * delta * delta, capHalf + slope * delta)
    }
}

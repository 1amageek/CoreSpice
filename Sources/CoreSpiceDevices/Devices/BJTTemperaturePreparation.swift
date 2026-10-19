import Foundation

/// Pinned SPICE3 default temperature law for the admitted low-injection BJT subset.
enum BJTTemperaturePreparation {
    static func prepare(_ source: BJTModelParameters, device: String) throws -> BJTModelParameters {
        var result = source
        let temperature = source.operatingTemperature, nominal = source.nominalTemperature
        let thermal = source.thermalVoltage
        guard thermal.isFinite, thermal > 0,
              (source.forwardEmissionCoefficient * thermal).isFinite,
              source.forwardEmissionCoefficient * thermal > 0,
              (source.reverseEmissionCoefficient * thermal).isFinite,
              source.reverseEmissionCoefficient * thermal > 0 else {
            throw failure(device, "Invalid derived BJT thermal voltage")
        }
        if temperature != nominal {
            let ratio = temperature / nominal
            let logarithmicFactor = (ratio - 1) * 1.11 / thermal + 3 * log(ratio)
            result.saturationCurrent = source.saturationCurrent * exp(logarithmicFactor)
            let nominalRatio = nominal / 300.15, actualRatio = temperature / 300.15
            let oldCorrection = potentialCorrection(nominal), newCorrection = potentialCorrection(temperature)
            func junction(_ capacitance: Double, _ potential: Double, _ grading: Double) throws -> (Double, Double) {
                let zeroPotential = (potential - oldCorrection) / nominalRatio
                let oldGamma = (potential - zeroPotential) / zeroPotential
                let newPotential = actualRatio * zeroPotential + newCorrection
                let newGamma = (newPotential - zeroPotential) / zeroPotential
                let oldFactor = 1 + grading * (4e-4 * (nominal - 300.15) - oldGamma)
                let newFactor = 1 + grading * (4e-4 * (temperature - 300.15) - newGamma)
                let newCapacitance = capacitance / oldFactor * newFactor
                guard zeroPotential.isFinite, zeroPotential > 0, newPotential.isFinite, newPotential > 0,
                      oldFactor.isFinite, oldFactor > 0, newFactor.isFinite, newFactor > 0,
                      newCapacitance.isFinite, newCapacitance >= 0,
                      capacitance == 0 || newCapacitance > 0 else {
                    throw failure(device, "Invalid temperature-adjusted BJT junction potential or capacitance")
                }
                return (newCapacitance, newPotential)
            }
            let be = try junction(source.baseEmitterCapacitance, source.baseEmitterPotential, source.baseEmitterGradingCoeff)
            let bc = try junction(source.baseCollectorCapacitance, source.baseCollectorPotential, source.baseCollectorGradingCoeff)
            result.baseEmitterCapacitance = be.0; result.baseEmitterPotential = be.1
            result.baseCollectorCapacitance = bc.0; result.baseCollectorPotential = bc.1
        }
        try result.validate(device: device)
        return result
    }

    private static func potentialCorrection(_ temperature: Double) -> Double {
        let thermal = 1.38064852e-23 * temperature / 1.6021766208e-19
        let ratio = temperature / 300.15
        let gap = 1.16 - 7.02e-4 * temperature * temperature / (temperature + 1108)
        return gap - ratio * 1.1150877 - 3 * thermal * log(ratio)
    }
    private static func failure(_ device: String, _ message: String) -> DeviceBindingError {
        .invalidParameterValue(device: device, parameter: "temperature", message: message)
    }
}

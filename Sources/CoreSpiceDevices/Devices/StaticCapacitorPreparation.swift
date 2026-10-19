import CoreSpiceIR
import Foundation

/// Strict static capacitor model/instance preparation using the original passive law.
enum StaticCapacitorPreparation {
    struct Prepared: Sendable {
        let capacitance: Double
        let initialVoltage: Double
        let hasInitialCondition: Bool
    }
    private static let vacuumPermittivity = 1 / (4 * Double.pi * 1e-7 * 299_792_458 * 299_792_458)
    static func prepare(_ instance: Instance, conditions: OperatingConditions) throws -> Prepared {
        let input = instance.parameters, model = instance.model?.parameters ?? [:]
        func invalid(_ key: String, _ message: String) -> DeviceBindingError {
            .invalidParameterValue(device: instance.name, parameter: key, message: message)
        }
        if let selected = instance.model, selected.typeName != "capacitor" {
            throw invalid("model", "Model type '\(selected.typeName)' does not match capacitor")
        }
        let instanceKeys = CapacitorDescriptor.staticInstanceParameterNames
        let modelKeys = CapacitorDescriptor.staticModelParameterNames
        for (values, supported) in [(input, instanceKeys), (model, modelKeys)] {
            for key in values.keys.sorted() {
                guard supported.contains(key) else { throw invalid(key, "Unsupported static capacitor parameter") }
                guard case .real(let value) = values[key] else {
                    throw DeviceBindingError.invalidParameterType(device: instance.name, parameter: key, expected: "real")
                }
                guard value.isFinite else { throw invalid(key, "Parameter must be finite") }
            }
        }
        func real(_ names: [String], in values: [String: ParameterValue]) throws -> Double? {
            var result: Double?
            for name in names {
                guard case .real(let value) = values[name] else { continue }
                if let result, result != value { throw invalid(name, "Conflicting capacitor parameter aliases") }
                result = value
            }
            return result
        }
        _ = try real(["cj", "cox"], in: model)
        _ = try real(["cjsw", "capsw"], in: model)
        _ = try real(["defw", "w"], in: model)
        let nominal = try real(["tnom"], in: model).map { $0 + 273.15 } ?? conditions.nominalTemperatureKelvin
        let temperature = try real(["temp"], in: input).map { $0 + 273.15 }
            ?? (conditions.temperatureKelvin + (try real(["dtemp"], in: input) ?? 0))
        let tc1 = try real(["tc1"], in: input) ?? real(["tc1"], in: model) ?? 0
        let tc2 = try real(["tc2"], in: input) ?? real(["tc2"], in: model) ?? 0
        let difference = temperature - nominal
        let temperatureFactor = 1 + tc1 * difference + tc2 * difference * difference
        let scale = try real(["scale"], in: input) ?? 1
        let multiplier = try real(["m"], in: input) ?? 1
        guard nominal.isFinite, nominal > 0, temperature.isFinite, temperature > 0,
              temperatureFactor.isFinite, temperatureFactor > 0, scale > 0, multiplier > 0 else {
            throw invalid("temperature/scale/m", "Temperature, scale and multiplicity must be finite and positive")
        }
        let supplied = try real(["c"], in: input), modelCap = try real(["cap"], in: model)
        let nominalCapacitance: Double
        if let supplied { nominalCapacitance = supplied }
        else if let modelCap { nominalCapacitance = modelCap }
        else if instance.model != nil {
            let width = try real(["w"], in: input) ?? real(["defw", "w"], in: model) ?? 10e-6
            let length = try real(["l"], in: input) ?? 0
            let correction = 2 * (try real(["del"], in: model) ?? 0)
            let narrow = try real(["narrow"], in: model) ?? correction
            let short = try real(["short"], in: model) ?? correction
            let effectiveWidth = width - narrow, effectiveLength = length - short
            var bottom = try real(["cj", "cox"], in: model)
            if bottom == nil, let thickness = try real(["thick"], in: model) {
                guard thickness > 0 else { throw invalid("thick", "Capacitor dielectric thickness must be positive") }
                if let dielectric = try real(["di"], in: model) {
                    guard dielectric > 0 else { throw invalid("di", "Relative dielectric constant must be positive") }
                    bottom = dielectric * vacuumPermittivity / thickness
                } else { bottom = 3.9 * vacuumPermittivity / thickness }
            }
            let areaCap = bottom ?? 0, sideCap = try real(["cjsw", "capsw"], in: model) ?? 0
            guard effectiveWidth.isFinite, effectiveWidth > 0, effectiveLength.isFinite, effectiveLength >= 0,
                  areaCap.isFinite, areaCap >= 0, sideCap >= 0 else {
                throw invalid("geometry", "Effective capacitor dimensions and capacitance densities are outside their passive domain")
            }
            nominalCapacitance = areaCap * effectiveWidth * effectiveLength + 2 * sideCap * (effectiveWidth + effectiveLength)
        } else { throw DeviceBindingError.missingParameter(device: instance.name, parameter: "c") }
        let total = nominalCapacitance * temperatureFactor * scale * multiplier
        guard nominalCapacitance.isFinite, nominalCapacitance > 0, total.isFinite, total > 0 else {
            throw invalid("c", "Effective total capacitance must be finite and positive")
        }
        return Prepared(capacitance: total, initialVoltage: try real(["ic"], in: input) ?? 0,
            hasInitialCondition: input["ic"] != nil)
    }
}

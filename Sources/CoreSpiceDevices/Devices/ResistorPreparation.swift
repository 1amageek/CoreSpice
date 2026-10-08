import Foundation
import CoreSpiceIR

/// Admits original instance/model roles and prepares the pinned static resistor law.
struct ResistorPreparation {
    static func prepare(instance: Instance, conditions: OperatingConditions) throws -> StaticResistorParameters {
        let device = instance.name
        if let model = instance.model, model.typeName != "resistor" {
            throw invalid(device, "model", "Referenced model must have resistor type")
        }
        let supplied = try normalized(instance.parameters, device: device)
        let model = try normalized(instance.model?.parameters ?? [:], device: device)
        let instanceKeys: Set<String> = ["r", "resistance", "ac", "temp", "dtemp", "l", "w", "m",
            "tc", "tc1", "tc2", "tce", "scale", "noisy", "noise"]
        let modelKeys: Set<String> = ["r", "res", "rsh", "narrow", "dw", "short", "dlr", "tc1", "tc1r",
            "tc2", "tc2r", "tce", "defw", "w", "l", "kf", "af", "tnom", "lf", "wf", "ef"]
        for key in supplied.keys.sorted() where !instanceKeys.contains(key) {
            throw invalid(device, key, "Unsupported resistor instance parameter")
        }
        for key in model.keys.sorted() where !modelKeys.contains(key) {
            throw invalid(device, key, "Unsupported resistor model parameter")
        }
        // FIXME(INCOMPLETE_IMPLEMENTATION):
        // Public parse/lower preserves runtime resistance and its canonical dependencies.
        // Registry binding refuses this branch until current, complete Jacobian, AC,
        // transient and original runtime noise semantics have behavioral evidence.
        for key in ["r", "resistance"] {
            if case .behavioralExpression = supplied[key] {
                throw invalid(device, key, "Runtime-dependent resistance is not implemented")
            }
        }
        func read(_ names: [String], _ values: [String: ParameterValue]) throws -> Double? {
            var result: Double?
            for name in names {
                guard let value = values[name] else { continue }
                let number: Double
                if case .real(let real) = value { number = real }
                else if (name == "noisy" || name == "noise"), case .integer(let flag) = value { number = Double(flag) }
                else {
                    throw DeviceBindingError.invalidParameterType(device: device, parameter: name, expected: "finite real")
                }
                guard number.isFinite else { throw invalid(device, name, "Parameter must be finite") }
                if let result, result != number { throw invalid(device, name, "Conflicting parameter aliases") }
                result = number
            }
            return result
        }
        // Admit every supplied scalar, including defaults overridden by the instance.
        for (name, _) in supplied { if name != "r" && name != "resistance" { _ = try read([name], supplied) } }
        for (name, _) in model { _ = try read([name], model) }
        for aliases in [["defw", "w"], ["short", "dlr"], ["narrow", "dw"],
                        ["tc1", "tc1r"], ["tc2", "tc2r"]] { _ = try read(aliases, model) }
        let explicitResistance = try read(["r", "resistance"], supplied)
        let modelResistance = try read(["r", "res"], model)
        if let explicitResistance { try positive(explicitResistance, device, "r") }
        if let modelResistance { try positive(modelResistance, device, "model.r") }
        let length = try read(["l"], supplied) ?? read(["l"], model) ?? 10e-6
        let width = try read(["w"], supplied) ?? read(["defw", "w"], model) ?? 10e-6
        try positive(length, device, "l")
        try positive(width, device, "w")
        let shortening = try read(["short", "dlr"], model) ?? 0
        let narrowing = try read(["narrow", "dw"], model) ?? 0
        let effectiveLength = length - 2 * shortening
        let effectiveWidth = width - 2 * narrowing
        let sheetResistance = try read(["rsh"], model) ?? 0
        guard sheetResistance >= 0 else { throw invalid(device, "rsh", "Sheet resistance must be nonnegative") }
        let usesGeometry = explicitResistance == nil && sheetResistance > 0
        let sourceDimensions = supplied["l"] != nil || supplied["w"] != nil
        if usesGeometry || sourceDimensions {
            try positive(effectiveLength, device, "effectiveLength")
            try positive(effectiveWidth, device, "effectiveWidth")
        }
        let resistance: Double
        if let explicitResistance { resistance = explicitResistance }
        else if usesGeometry { resistance = sheetResistance * (effectiveLength / effectiveWidth) }
        else if let modelResistance { resistance = modelResistance }
        else { throw DeviceBindingError.missingParameter(device: device, parameter: "r or valid model geometry/default") }
        try positive(resistance, device, "resistance")
        let nominal = try read(["tnom"], model).map { $0 + 273.15 } ?? conditions.nominalTemperatureKelvin
        try positive(nominal, device, "tnom")
        let absoluteTemperature = try read(["temp"], supplied).map { $0 + 273.15 }
        let deltaTemperature = try read(["dtemp"], supplied) ?? 0
        let temperature = absoluteTemperature ?? (conditions.temperatureKelvin + deltaTemperature)
        try positive(temperature, device, "temp")
        let difference = temperature - nominal
        guard difference.isFinite else { throw invalid(device, "temperatureDifference", "Temperature difference overflow") }
        let tc1 = try read(["tc1", "tc"], supplied) ?? read(["tc1", "tc1r"], model) ?? 0
        let tc2 = try read(["tc2"], supplied) ?? read(["tc2", "tc2r"], model) ?? 0
        let tce = try read(["tce"], supplied) ?? read(["tce"], model)
        let factor = tce.map { pow(1.01, $0 * difference) } ?? ((tc2 * difference + tc1) * difference + 1)
        try positive(factor, device, "temperatureFactor")
        let multiplier = try read(["m"], supplied) ?? 1
        let scale = try read(["scale"], supplied) ?? 1
        try positive(multiplier, device, "m")
        try positive(scale, device, "scale")
        func conductance(_ resistance: Double, name: String) throws -> Double {
            try positive(resistance, device, name)
            let denominator = resistance * factor * scale
            try positive(denominator, device, "\(name).effective")
            let value = multiplier / denominator
            try positive(value, device, "\(name).conductance")
            return value
        }
        let dc = try conductance(resistance, name: "r")
        let ac = try conductance(read(["ac"], supplied) ?? resistance, name: "ac")
        let noiseFlag = try read(["noisy", "noise"], supplied) ?? 1
        guard noiseFlag == 0 || noiseFlag == 1 else { throw invalid(device, "noisy", "Noise flag must be zero or one") }
        let noiseTemperature = absoluteTemperature.map { $0 + (nominal - 273.15) } ?? temperature
        try positive(noiseTemperature, device, "noiseTemperature")
        let coefficient = try read(["kf"], model) ?? 0
        guard coefficient >= 0 else { throw invalid(device, "kf", "Flicker coefficient must be nonnegative") }
        let af = try read(["af"], model) ?? 1
        let ef = try read(["ef"], model) ?? 1
        let lf = try read(["lf"], model) ?? 1
        let wf = try read(["wf"], model) ?? 1
        let area = sourceDimensions ? pow(effectiveLength, lf) * pow(effectiveWidth, wf) : 1
        try positive(area, device, "effectiveNoiseArea")
        let thermal = 4 * 1.380649e-23 * noiseTemperature * dc
        guard thermal.isFinite, thermal >= 0 else { throw invalid(device, "thermalNoise", "Thermal spectrum overflow") }
        return StaticResistorParameters(conductance: dc, acConductance: ac,
            noiseTemperatureKelvin: noiseTemperature, multiplier: multiplier, noisy: noiseFlag == 1,
            flickerCoefficient: coefficient, flickerCurrentExponent: af, flickerFrequencyExponent: ef,
            effectiveNoiseArea: area)
    }

    private static func normalized(_ values: [String: ParameterValue], device: String) throws -> [String: ParameterValue] {
        var result: [String: ParameterValue] = [:]
        for (key, value) in values {
            let normalized = key.lowercased()
            if result[normalized] != nil { throw invalid(device, key, "Duplicate case-insensitive parameter") }
            result[normalized] = value
        }
        return result
    }

    private static func positive(_ value: Double, _ device: String, _ parameter: String) throws {
        guard value.isFinite, value > 0 else { throw invalid(device, parameter, "Value must be finite and positive") }
    }

    private static func invalid(_ device: String, _ parameter: String, _ message: String) -> DeviceBindingError {
        .invalidParameterValue(device: device, parameter: parameter, message: message)
    }
}

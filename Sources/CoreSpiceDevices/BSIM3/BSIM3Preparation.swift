import CoreSpiceCompactModels
import CoreSpiceIR

/// One authority for cold admission and original auxiliary-node requirements.
public enum BSIM3Preparation {
    public static func prepare(model: ResolvedDeviceModel, instanceParameters: [String: ParameterValue],
                               temperature: Double = 300.15) throws -> BSIM3PreparedDevice {
        let polarity: BSIM3Configuration.Polarity
        switch model.typeName {
        case "nmos_l49": polarity = .nmos
        case "pmos_l49": polarity = .pmos
        default: throw BSIM3DeviceError.modelTypeMismatch(model.typeName)
        }
        var modelParameters: [String: Double] = [:]
        var version = "3.3.0"
        for (name, value) in model.parameters {
            if name == "version" {
                guard case .string(let identity) = value else {
                    throw BSIM3Error.invalidConfiguration("Model version must retain its exact string identity")
                }
                version = identity
            } else { modelParameters[name] = try real(value, name: name, model: true) }
        }
        var parameters: [String: Double] = [:]
        var initial = SIMD3<Double>(repeating: 0)
        var hasInitial = false
        var multiplier = 1.0
        for (name, value) in instanceParameters {
            let number = try real(value, name: name, model: false)
            switch name {
            case "m": multiplier = number
            case "ic_vds": initial[0] = number; hasInitial = true
            case "ic_vgs": initial[1] = number; hasInitial = true
            case "ic_vbs": initial[2] = number; hasInitial = true
            default: parameters[name] = number
            }
        }
        guard multiplier.isFinite, multiplier > 0 else {
            throw BSIM3Error.invalidParameter(name: "m", model: false)
        }
        let configuration = BSIM3Configuration(polarity: polarity, version: version, temperature: temperature,
            modelParameters: modelParameters, instanceParameters: parameters,
            initialConditions: hasInitial ? initial : nil)
        return try BSIM3PreparedDevice(evaluator: BSIM3Evaluator(configuration: configuration),
            multiplier: multiplier, initialConditions: hasInitial ? initial : nil)
    }

    private static func real(_ value: ParameterValue, name: String, model: Bool) throws -> Double {
        switch value {
        case .real(let number) where number.isFinite: return number
        case .integer(let number): return Double(number)
        default: throw BSIM3Error.invalidParameter(name: name, model: model)
        }
    }
}

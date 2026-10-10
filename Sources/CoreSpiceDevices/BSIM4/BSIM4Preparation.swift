import CoreSpiceCompactModels
import CoreSpiceIR

/// One authority for cold admission and original auxiliary-node requirements.
public enum BSIM4Preparation {
    public static func prepare(model: ResolvedDeviceModel, instanceParameters: [String: ParameterValue],
                               temperature: Double = 300.15, policy: BSIM4PreparationPolicy?, noisePreparationRequested: Bool) throws -> BSIM4PreparedDevice {
        guard let policy else { throw BSIM4DeviceError.missingPreparationPolicy(model.name) }
        let polarity: BSIM4Configuration.Polarity
        switch model.typeName {
        case "nmos_l54": polarity = .nmos
        case "pmos_l54": polarity = .pmos
        default: throw BSIM4DeviceError.modelTypeMismatch(model.typeName)
        }
        var modelParameters: [String: Double] = [:]
        var version = "4.8.3"
        var seenModel = Set<String>()
        for (key, value) in model.parameters {
            let name = key.lowercased()
            guard seenModel.insert(name).inserted else {
                throw BSIM4Error.invalidParameter(name: name, model: true)
            }
            if name == "version" {
                guard case .string(let identity) = value else {
                    throw BSIM4Error.invalidConfiguration("Model version must retain its exact string identity")
                }
                version = identity
            } else { modelParameters[name] = try real(value, name: name, model: true) }
        }
        var parameters: [String: Double] = [:]
        var initial = SIMD3<Double>(repeating: 0)
        var hasInitial = false
        var multiplier = 1.0
        var seenInstance = Set<String>()
        for (key, value) in instanceParameters {
            let name = key.lowercased()
            guard seenInstance.insert(name).inserted else { throw BSIM4Error.invalidParameter(name: name, model: false) }
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
            throw BSIM4Error.invalidParameter(name: "m", model: false)
        }
        let configuration = BSIM4Configuration(polarity: polarity, version: version, temperature: temperature,
            noiseRequested: noisePreparationRequested, maximumStressIterations: policy.maximumStressIterations,
            modelParameters: modelParameters, instanceParameters: parameters,
            initialConditions: hasInitial ? initial : nil)
        return try BSIM4PreparedDevice(configuration: configuration,
            multiplier: multiplier, initialConditions: hasInitial ? initial : nil, policy: policy)
    }

    private static func real(_ value: ParameterValue, name: String, model: Bool) throws -> Double {
        switch value {
        case .real(let number) where number.isFinite: return number
        case .integer(let number): return Double(number)
        default: throw BSIM4Error.invalidParameter(name: name, model: model)
        }
    }
}

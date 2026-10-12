import CoreSpiceEvaluationContracts

public enum DiodeThermalInput: Sendable, Hashable {
    case ambient
    case absolute(TemperatureKelvin)
    case offset(TemperatureDelta)

    public func effectiveTemperature(in environment: borrowing EvaluationEnvironment) throws(TemperatureFailure) -> TemperatureKelvin {
        switch self {
        case .ambient: environment.ambient
        case .absolute(let temperature): temperature
        case .offset(let delta): try environment.ambient.applying(delta)
        }
    }
}

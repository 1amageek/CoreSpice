public struct EvaluationEnvironment: Sendable, Hashable {
    public let ambient: TemperatureKelvin
    public let nominal: TemperatureKelvin
    public var identity: EvaluationEnvironmentIdentity { .init(ambient: ambient, nominal: nominal) }

    public init(ambient: TemperatureKelvin, nominal: TemperatureKelvin) {
        self.ambient = ambient
        self.nominal = nominal
    }

    public init(identity: EvaluationEnvironmentIdentity) throws(TemperatureFailure) {
        ambient = try TemperatureKelvin(Double(bitPattern: identity.ambientKelvinBits))
        nominal = try TemperatureKelvin(Double(bitPattern: identity.nominalKelvinBits))
    }
}

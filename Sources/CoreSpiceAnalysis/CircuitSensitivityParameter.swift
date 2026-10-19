/// A source owner's canonical scalar parameter exposed for numeric reexecution.
public struct CircuitSensitivityParameter: Sendable {
    public let deviceName: String
    public let parameterName: String
    /// Value in the source replacement coordinate, including original geometry scale units.
    public let nominalValue: Double

    public init(deviceName: String, parameterName: String, nominalValue: Double) {
        self.deviceName = deviceName
        self.parameterName = parameterName
        self.nominalValue = nominalValue
    }
}

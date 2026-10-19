/// A pre-existing voltage-source boundary; its terminal order defines port orientation.
public struct NetworkPort: Sendable, Equatable {
    public let voltageSourceName: String
    public let referenceImpedance: Double

    public init(voltageSourceName: String, referenceImpedance: Double) throws {
        guard !voltageSourceName.isEmpty, referenceImpedance.isFinite, referenceImpedance > 0 else {
            throw NetworkParameterError.invalidPort(voltageSourceName)
        }
        self.voltageSourceName = voltageSourceName
        self.referenceImpedance = referenceImpedance
    }
}

import OSDIContracts

/// A profile transformation; absent providerValue means source selection metadata only.
public struct ExternalMOSParameterFact: Sendable, Equatable {
    public let address: ExternalMOSScalarAddress?
    public let name: String
    public let role: OSDIParameterScope
    public let rawValue: Double?
    public let normalizedValue: Double?
    public let providerValue: OSDIParameterValue?
    public let isGiven: Bool

    public init(address: ExternalMOSScalarAddress?, name: String, role: OSDIParameterScope,
                rawValue: Double?, normalizedValue: Double?, providerValue: OSDIParameterValue?, isGiven: Bool) {
        self.address = address; self.name = name; self.role = role; self.rawValue = rawValue
        self.normalizedValue = normalizedValue; self.providerValue = providerValue; self.isGiven = isGiven
    }
}

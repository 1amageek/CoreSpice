/// Immutable, explicit-profile preparation evidence; not a numerical qualification.
public struct ExternalMOSPreparationFacts: Sendable, Equatable {
    public let profileIdentity: String
    public let geometry: ExternalMOSGeometry
    public let parameters: [ExternalMOSParameterFact]

    public init(profileIdentity: String, geometry: ExternalMOSGeometry, parameters: [ExternalMOSParameterFact]) {
        self.profileIdentity = profileIdentity; self.geometry = geometry; self.parameters = parameters
    }
}

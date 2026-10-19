import CoreSpiceEvaluationContracts

/// Semantic inspection identity; pointer addresses and model names are not authority.
public struct DiodePreparationIdentity: Sendable, Equatable {
    public let resolved: ResolvedDiodeInstance
    public let environment: EvaluationEnvironmentIdentity
    public let effectiveTemperature: TemperatureKelvin
    public let implementationIdentity: String
    public let anodeNodeID: Int
    public let cathodeNodeID: Int
    public let analyses: DiodeAnalysisCapabilities
    package init(input: borrowing DiodePreparationInput, effectiveTemperature: TemperatureKelvin,
                 implementationIdentity: String) {
        anodeNodeID = input.anodeNodeID; cathodeNodeID = input.cathodeNodeID
        resolved = input.resolved; environment = input.environment.identity
        self.effectiveTemperature = effectiveTemperature
        self.implementationIdentity = implementationIdentity; analyses = input.analyses
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        let a = lhs.resolved, b = rhs.resolved
        guard lhs.anodeNodeID == rhs.anodeNodeID, lhs.cathodeNodeID == rhs.cathodeNodeID,
              lhs.environment == rhs.environment, lhs.effectiveTemperature == rhs.effectiveTemperature,
              lhs.implementationIdentity == rhs.implementationIdentity, lhs.analyses == rhs.analyses,
              a.instance == b.instance, a.scope == b.scope, a.invocation == b.invocation,
              a.profile == b.profile, a.environment == b.environment,
              a.evaluatorVersion == b.evaluatorVersion, a.randomGeneratorVersion == b.randomGeneratorVersion,
              a.seed == b.seed, a.orderedAssignmentEvidence == b.orderedAssignmentEvidence,
              a.model.declaration == b.model.declaration,
              a.model.orderedAssignmentEvidence == b.model.orderedAssignmentEvidence,
              a.model.input.schemaIdentity == b.model.input.schemaIdentity,
              a.input.rawGeometry == b.input.rawGeometry, a.input.geometry == b.input.geometry, a.input.multiplicity == b.input.multiplicity,
              a.input.thermal == b.input.thermal else { return false }
        for index in 0..<12 {
            guard let id = DiodeModelParameterID(rawValue: index),
                  a.model.input.value(for: id) == b.model.input.value(for: id),
                  a.model.input.origin(for: id) == b.model.input.origin(for: id) else { return false }
        }
        for index in 0..<5 {
            guard let id = DiodeInstanceParameterID(rawValue: index),
                  a.input.origin(for: id) == b.input.origin(for: id) else { return false }
        }
        return true
    }
}

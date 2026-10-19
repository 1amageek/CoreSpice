import CoreSpiceEvaluationContracts

public struct DiodePreparationInput: Sendable {
    public let resolved: ResolvedDiodeInstance
    public let environment: EvaluationEnvironment
    public let anodeNodeID: Int
    public let cathodeNodeID: Int
    public let analyses: DiodeAnalysisCapabilities
    public init(resolved: ResolvedDiodeInstance, environment: EvaluationEnvironment,
                analyses: DiodeAnalysisCapabilities, anodeNodeID: Int, cathodeNodeID: Int) throws(DiodePreparationFailure) {
        guard anodeNodeID >= 0, cathodeNodeID >= 0, !analyses.isEmpty, analyses.subtracting(.all).isEmpty else { throw .invalidConditions }
        do { try Self.validate(resolved, environment: environment) }
        catch { throw .schema(error) }
        self.anodeNodeID = anodeNodeID; self.cathodeNodeID = cathodeNodeID
        self.resolved = resolved; self.environment = environment; self.analyses = analyses
    }
    private static func validate(_ resolved: ResolvedDiodeInstance,
                                 environment: borrowing EvaluationEnvironment) throws(DiodeSchemaFailure) {
        try resolved.model.input.validateEnvironment(environment)
        try resolved.input.validateEnvironment(environment)
        guard resolved.environment == environment.identity,
              resolved.model.input.schemaIdentity == resolved.input.schemaIdentity,
              resolved.model.input.schemaIdentity.law == (try resolved.profile.modelLaw(level: nil, version: nil)) else {
            throw .environmentMismatch
        }
    }
}

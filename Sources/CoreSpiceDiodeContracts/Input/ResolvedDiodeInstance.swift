import CoreSpiceEvaluationContracts

/// Reusable checked resolution; this value provides no numerical execution capability.
public struct ResolvedDiodeInstance: Sendable {
    public let instance: String
    public let scope: UInt32
    public let invocation: UInt64
    public let model: ResolvedDiodeModel
    public let input: DiodeInstanceInput
    public let profile: DiodeInputProfile
    public let environment: EvaluationEnvironmentIdentity
    public let evaluatorVersion: String
    public let randomGeneratorVersion: String
    public let seed: UInt64
    public let orderedAssignmentEvidence: Bool
    package init(instance: String, scope: UInt32, invocation: UInt64, model: ResolvedDiodeModel,
                 input: DiodeInstanceInput, profile: DiodeInputProfile, seed: UInt64,
                 evaluatorVersion: String, randomGeneratorVersion: String,
                 orderedAssignmentEvidence: Bool) throws(DiodeSchemaFailure) {
        guard model.input.environmentIdentity == input.environmentIdentity,
              model.input.schemaIdentity == input.schemaIdentity else { throw .environmentMismatch }
        self.instance = instance; self.scope = scope; self.invocation = invocation
        self.model = model; self.input = input; self.profile = profile; self.seed = seed
        self.evaluatorVersion = evaluatorVersion; self.randomGeneratorVersion = randomGeneratorVersion
        environment = input.environmentIdentity
        self.orderedAssignmentEvidence = orderedAssignmentEvidence
    }
}

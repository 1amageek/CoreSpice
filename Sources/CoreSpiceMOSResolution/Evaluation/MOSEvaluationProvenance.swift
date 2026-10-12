import CoreSpiceEvaluationContracts
/// Immutable trace transferred only when the exclusive session is consumed.
public struct MOSEvaluationProvenance: Sendable {
    public let environment: EvaluationEnvironment?
    public let seed: UInt64
    public let randomGeneratorVersion: String
    public let evaluatorVersion: String
    public let randomDraws: UInt64
    public let rootVisits: [MOSRootVisit]
}

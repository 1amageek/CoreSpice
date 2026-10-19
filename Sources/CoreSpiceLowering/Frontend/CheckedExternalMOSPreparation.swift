/// Lowering-admitted source/result association and actual scalar evaluation trace.
public struct CheckedExternalMOSPreparation: Sendable {
    public let preparation: ExternalMOSPreparation
    public let evaluatedScalars: [ExternalMOSEvaluatedScalar]
}

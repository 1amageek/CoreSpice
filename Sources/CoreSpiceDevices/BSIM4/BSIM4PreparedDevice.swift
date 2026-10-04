import CoreSpiceCompactModels

/// Admitted original evaluator and the adapter-owned instance semantics.
public struct BSIM4PreparedDevice: Sendable {
    public let evaluator: any BSIM4Evaluating
    public let policy: BSIM4PreparationPolicy
    public let multiplier: Double
    public let initialConditions: SIMD3<Double>?
    public var auxiliaryNodeCount: Int { evaluator.topology.nodeCount - 4 }
}

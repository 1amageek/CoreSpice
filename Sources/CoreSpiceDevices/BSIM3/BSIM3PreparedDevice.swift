import CoreSpiceCompactModels

/// Admitted original evaluator and the adapter-owned instance semantics.
public struct BSIM3PreparedDevice: Sendable {
    public let evaluator: any BSIM3Evaluating
    public let multiplier: Double
    public let initialConditions: SIMD3<Double>?
    public var auxiliaryNodeCount: Int { evaluator.topology.nodeCount - 4 }
}

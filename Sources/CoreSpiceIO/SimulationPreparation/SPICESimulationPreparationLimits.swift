import CoreSpiceAnalysis

/// Finite caller policy; grammar, transformation and numerical policies have distinct owners.
public struct SPICESimulationPreparationLimits: Sendable {
    public let maximumElements: Int
    public let maximumTransformBytes: UInt64
    public let maximumSweepPoints: Int
    public let maximumPageByteCount: UInt64
    public let numerical: TransientExecutionLimits
    public init(maximumElements: Int, maximumTransformBytes: UInt64, maximumSweepPoints: Int,
                maximumPageByteCount: UInt64, numerical: TransientExecutionLimits) {
        self.maximumElements = maximumElements; self.maximumTransformBytes = maximumTransformBytes
        self.maximumSweepPoints = maximumSweepPoints; self.maximumPageByteCount = maximumPageByteCount
        self.numerical = numerical
    }
}

/// Additional observation storage ceilings; work remains on the original flow's control.
public struct NativePrescribedVoltageFlowObservationLimits: Sendable {
    public let maximumPairCount: Int
    public let maximumRetainedBytes: Int
    public let maximumWorkspaceBytes: Int
    public init(maximumPairCount: Int, maximumRetainedBytes: Int, maximumWorkspaceBytes: Int) {
        self.maximumPairCount = maximumPairCount
        self.maximumRetainedBytes = maximumRetainedBytes; self.maximumWorkspaceBytes = maximumWorkspaceBytes
    }
}

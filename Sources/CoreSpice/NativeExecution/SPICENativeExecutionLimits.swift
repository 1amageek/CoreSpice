import CoreSpiceMOSContracts

public struct SPICENativeExecutionLimits: Sendable, Hashable {
    public let maximumDeviceCount: Int
    public let maximumMatrixDimension: Int
    public let maximumAllocationBytes: UInt64
    public let mosPreparationLimits: MOSPreparationLimits?
    public let mosPreparationConditions: MOSPreparationConditions?
    public init(maximumDeviceCount: Int, maximumMatrixDimension: Int, maximumAllocationBytes: UInt64,
                mosPreparationLimits: MOSPreparationLimits? = nil, mosPreparationConditions: MOSPreparationConditions? = nil) {
        self.maximumDeviceCount = maximumDeviceCount; self.maximumMatrixDimension = maximumMatrixDimension
        self.maximumAllocationBytes = maximumAllocationBytes
        self.mosPreparationLimits = mosPreparationLimits; self.mosPreparationConditions = mosPreparationConditions
    }
}

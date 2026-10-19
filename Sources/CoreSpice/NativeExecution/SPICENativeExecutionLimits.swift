import CoreSpiceMOSContracts
import CoreSpiceDiodeContracts

public struct SPICENativeExecutionLimits: Sendable, Hashable {
    public let maximumDeviceCount: Int
    public let maximumMatrixDimension: Int
    public let maximumAllocationBytes: UInt64
    public let mosPreparationLimits: MOSPreparationLimits?
    public let mosPreparationConditions: MOSPreparationConditions?
    public let diodePreparationLimits: DiodePreparationLimits?
    public let diodeAnalyses: DiodeAnalysisCapabilities?
    public init(maximumDeviceCount: Int, maximumMatrixDimension: Int, maximumAllocationBytes: UInt64,
                mosPreparationLimits: MOSPreparationLimits? = nil, mosPreparationConditions: MOSPreparationConditions? = nil,
                diodePreparationLimits: DiodePreparationLimits? = nil, diodeAnalyses: DiodeAnalysisCapabilities? = nil) {
        self.maximumDeviceCount = maximumDeviceCount; self.maximumMatrixDimension = maximumMatrixDimension
        self.maximumAllocationBytes = maximumAllocationBytes
        self.diodePreparationLimits = diodePreparationLimits; self.diodeAnalyses = diodeAnalyses
        self.mosPreparationLimits = mosPreparationLimits; self.mosPreparationConditions = mosPreparationConditions
    }
}

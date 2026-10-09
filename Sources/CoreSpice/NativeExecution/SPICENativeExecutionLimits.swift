public struct SPICENativeExecutionLimits: Sendable, Hashable {
    public let maximumDeviceCount: Int
    public let maximumMatrixDimension: Int
    public let maximumAllocationBytes: UInt64
    public init(maximumDeviceCount: Int, maximumMatrixDimension: Int, maximumAllocationBytes: UInt64) {
        self.maximumDeviceCount = maximumDeviceCount; self.maximumMatrixDimension = maximumMatrixDimension
        self.maximumAllocationBytes = maximumAllocationBytes
    }
}

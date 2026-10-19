public struct DiodePreparationLimits: Sendable, Hashable {
    public let maximumRetainedBytes: UInt64
    public let maximumTemporaryBytes: UInt64
    public let maximumWorkUnits: UInt64
    public init(maximumRetainedBytes: UInt64, maximumTemporaryBytes: UInt64,
                maximumWorkUnits: UInt64) throws(DiodePreparationFailure) {
        guard maximumRetainedBytes > 0, maximumTemporaryBytes > 0, maximumWorkUnits > 0 else {
            throw .invalidLimits
        }
        self.maximumRetainedBytes = maximumRetainedBytes
        self.maximumTemporaryBytes = maximumTemporaryBytes
        self.maximumWorkUnits = maximumWorkUnits
    }
}

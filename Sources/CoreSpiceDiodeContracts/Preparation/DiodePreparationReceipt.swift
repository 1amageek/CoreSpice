/// Inspection-only evidence. Executable ownership remains in Devices.
public struct DiodePreparationReceipt: Sendable, Equatable {
    public let identity: DiodePreparationIdentity
    public let requiredFeatures: DiodeFeatureSet
    public let retainedBytes: UInt64
    public let peakTemporaryBytes: UInt64
    public let workUnits: UInt64
    public let coldSetupCount: UInt32
    public var auxiliaryNodeCount: Int { 0 }
    package init(identity: DiodePreparationIdentity, requiredFeatures: DiodeFeatureSet,
                 retainedBytes: UInt64, peakTemporaryBytes: UInt64, workUnits: UInt64,
                 limits: DiodePreparationLimits) throws(DiodePreparationFailure) {
        guard retainedBytes > 0, retainedBytes <= limits.maximumRetainedBytes,
              peakTemporaryBytes <= limits.maximumTemporaryBytes else { throw .capacityExceeded }
        guard workUnits <= limits.maximumWorkUnits else { throw .workLimitExceeded }
        self.identity = identity; self.requiredFeatures = requiredFeatures
        self.retainedBytes = retainedBytes; self.peakTemporaryBytes = peakTemporaryBytes
        self.workUnits = workUnits; coldSetupCount = 1
    }
}

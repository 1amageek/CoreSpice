/// Inspection evidence only; this copyable value contains no mutable numerical owner.
public struct MOSPreparationReceipt: Sendable, Hashable {
    public let identity: MOSPreparationIdentity
    public let topology: MOSPreparedTopology
    public let retainedBytes: UInt64
    public let peakTemporaryBytes: UInt64
    public let coldSetupCount: UInt32

    package init(identity: MOSPreparationIdentity, topology: MOSPreparedTopology,
                 retainedBytes: UInt64, peakTemporaryBytes: UInt64, coldSetupCount: UInt32,
                 limits: MOSPreparationLimits) throws(MOSPreparationFailure) {
        guard coldSetupCount == 1, retainedBytes > 0 else { throw .invalidReceipt }
        guard retainedBytes <= limits.maximumRetainedBytes,
              peakTemporaryBytes <= limits.maximumTemporaryBytes else { throw .capacityExceeded }
        self.identity = identity; self.topology = topology
        self.retainedBytes = retainedBytes; self.peakTemporaryBytes = peakTemporaryBytes
        self.coldSetupCount = coldSetupCount
    }
}

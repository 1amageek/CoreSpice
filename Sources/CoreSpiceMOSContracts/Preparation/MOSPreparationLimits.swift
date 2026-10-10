/// Mandatory per-owner payload and work ceilings; no implicit unlimited policy.
public struct MOSPreparationLimits: Sendable, Hashable {
    public let maximumRetainedBytes: UInt64
    public let maximumTemporaryBytes: UInt64
    public let maximumDiagnosticBytes: UInt64
    public let maximumWorkUnits: UInt64

    public init(maximumRetainedBytes: UInt64, maximumTemporaryBytes: UInt64,
                maximumDiagnosticBytes: UInt64, maximumWorkUnits: UInt64) throws(MOSPreparationFailure) {
        guard maximumRetainedBytes > 0, maximumTemporaryBytes > 0,
              maximumDiagnosticBytes > 0, maximumWorkUnits > 0 else { throw .invalidLimits }
        self.maximumRetainedBytes = maximumRetainedBytes; self.maximumTemporaryBytes = maximumTemporaryBytes
        self.maximumDiagnosticBytes = maximumDiagnosticBytes; self.maximumWorkUnits = maximumWorkUnits
    }
}

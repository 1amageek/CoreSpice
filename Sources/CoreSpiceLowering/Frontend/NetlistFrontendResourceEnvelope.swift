import CoreSpiceMOSContracts

/// Checked simultaneous payload bounds for source-accounted frontend composition.
public struct NetlistFrontendResourceEnvelope: Sendable {
    public let maximumRetainedBytes: UInt64
    public let maximumTemporaryBytes: UInt64
    public let maximumSimultaneousBytes: UInt64

    public init(limits: MOSResolutionLimits) throws(MOSResolutionFailure) {
        let (retained, overflow) = limits.maximumRetainedBytes.multipliedReportingOverflow(by: 2)
        let (total, totalOverflow) = retained.addingReportingOverflow(limits.maximumRetainedBytes)
        guard !overflow, !totalOverflow else { throw .arithmeticOverflow }
        maximumRetainedBytes = retained
        maximumTemporaryBytes = limits.maximumRetainedBytes
        maximumSimultaneousBytes = total
    }
}

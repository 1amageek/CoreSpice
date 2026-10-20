import CoreSpiceAnalysis

/// Explicit capacities governed by the original prepared owner's cumulative control.
package struct NativePrescribedVoltageLimits: Sendable {
    package let maximumNativeTerms: Int
    package let maximumRetainedBytes: Int
    package let maximumWorkspaceBytes: Int
    package let precisionBits: UInt32
    package let reductionLimits: PrescribedVoltageReduction.Limits
    package init(maximumNativeTerms: Int, maximumRetainedBytes: Int, maximumWorkspaceBytes: Int,
        precisionBits: UInt32, reductionLimits: PrescribedVoltageReduction.Limits) {
        self.maximumNativeTerms = maximumNativeTerms; self.maximumRetainedBytes = maximumRetainedBytes
        self.maximumWorkspaceBytes = maximumWorkspaceBytes; self.precisionBits = precisionBits
        self.reductionLimits = reductionLimits
    }
}

import CoreSpiceAnalysis

/// Explicit chart ceilings governed by the actual preparation's original control.
package struct NativePrescribedVoltageChartLimits: Sendable {
    package let maximumTriplets: Int
    package let maximumRetainedBytes: Int
    package let maximumWorkspaceBytes: Int
    package let precisionBits: UInt32
    package let values: NativePrescribedVoltageLimits
    package let exact: ExactRowAlgebra.Limits
    package let root: ValidatedParametricRoot.Limits
    package init(maximumTriplets: Int, maximumRetainedBytes: Int, maximumWorkspaceBytes: Int,
        precisionBits: UInt32, values: NativePrescribedVoltageLimits, exact: ExactRowAlgebra.Limits,
        root: ValidatedParametricRoot.Limits) {
        self.maximumTriplets = maximumTriplets; self.maximumRetainedBytes = maximumRetainedBytes
        self.maximumWorkspaceBytes = maximumWorkspaceBytes; self.precisionBits = precisionBits
        self.values = values; self.exact = exact; self.root = root
    }
}

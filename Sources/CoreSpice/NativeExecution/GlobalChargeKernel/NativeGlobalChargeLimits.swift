import CoreSpiceAnalysis

/// Explicit caller ceilings; the existing preparation still owns all cumulative resources.
package struct NativeGlobalChargeLimits: Sendable {
    package let maximumNativeTerms: Int
    package let maximumRetainedBytes: Int
    package let maximumWorkspaceBytes: Int
    package let precisionBits: UInt32
    package let exact: ExactRowAlgebra.Limits
    package let regularity: ValidatedMatrixRegularity.Limits
    package init(maximumNativeTerms: Int, maximumRetainedBytes: Int, maximumWorkspaceBytes: Int,
        precisionBits: UInt32, exact: ExactRowAlgebra.Limits, regularity: ValidatedMatrixRegularity.Limits) {
        self.maximumNativeTerms = maximumNativeTerms
        self.maximumRetainedBytes = maximumRetainedBytes
        self.maximumWorkspaceBytes = maximumWorkspaceBytes
        self.precisionBits = precisionBits; self.exact = exact; self.regularity = regularity
    }
}

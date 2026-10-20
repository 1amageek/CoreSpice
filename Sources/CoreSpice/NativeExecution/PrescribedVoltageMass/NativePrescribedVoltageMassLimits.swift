/// Explicit native capacities; all allocations coexist under the original preparation control.
package struct NativePrescribedVoltageMassLimits: Sendable {
    package let maximumTriplets: Int
    package let maximumRetainedBytes: Int
    package let maximumWorkspaceBytes: Int
    package let precisionBits: UInt32
    package init(maximumTriplets: Int, maximumRetainedBytes: Int, maximumWorkspaceBytes: Int, precisionBits: UInt32) {
        self.maximumTriplets = maximumTriplets; self.maximumRetainedBytes = maximumRetainedBytes
        self.maximumWorkspaceBytes = maximumWorkspaceBytes; self.precisionBits = precisionBits
    }
}

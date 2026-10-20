/// Explicit retained and temporary capacities; execution uses the original prepared control.
package struct NativePrescribedVoltageReconstructionLimits: Sendable {
    package let maximumRetainedBytes: Int
    package let maximumWorkspaceBytes: Int
    package let precisionBits: UInt32
    package init(maximumRetainedBytes: Int, maximumWorkspaceBytes: Int, precisionBits: UInt32) {
        self.maximumRetainedBytes = maximumRetainedBytes
        self.maximumWorkspaceBytes = maximumWorkspaceBytes; self.precisionBits = precisionBits
    }
}

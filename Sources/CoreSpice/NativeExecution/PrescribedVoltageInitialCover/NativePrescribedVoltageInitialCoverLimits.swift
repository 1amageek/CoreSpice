/// Explicit finite-cover ceilings; all work uses the original preparation control.
package struct NativePrescribedVoltageInitialCoverLimits: Sendable {
    package let maximumAxes: Int
    package let maximumNodes: Int
    package let maximumDepth: Int
    package let maximumWorkspaceBytes: Int
    package let maximumRetainedBytes: Int
    package init(maximumAxes: Int, maximumNodes: Int, maximumDepth: Int,
        maximumWorkspaceBytes: Int, maximumRetainedBytes: Int) {
        self.maximumAxes = maximumAxes; self.maximumNodes = maximumNodes; self.maximumDepth = maximumDepth
        self.maximumWorkspaceBytes = maximumWorkspaceBytes; self.maximumRetainedBytes = maximumRetainedBytes
    }
}

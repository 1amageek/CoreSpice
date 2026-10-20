/// Explicit managed byte ceilings; the matched preparation owns cumulative work and storage.
package struct NativePrescribedVoltageEvolutionLimits: Sendable {
    package let maximumRetainedBytes: Int
    package let maximumWorkspaceBytes: Int
    package init(maximumRetainedBytes: Int, maximumWorkspaceBytes: Int) {
        self.maximumRetainedBytes = maximumRetainedBytes; self.maximumWorkspaceBytes = maximumWorkspaceBytes
    }
}

/// Contributes original physical transient equations without reconstructing them from a linearized stamp.
public protocol TransientPhysicalResidualContributing: BoundDevice {
    /// Adds signed terms to compiled global residual rows without advancing accepted history.
    func accumulateTransientPhysicalResidual(
        state: SolutionState, integration: IntegrationState, add: (Int, Double) -> Void
    ) throws
}

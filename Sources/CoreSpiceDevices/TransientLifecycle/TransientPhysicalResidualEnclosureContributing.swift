/// Supplies enclosed original transient equations at the represented paired state.
public protocol TransientPhysicalResidualEnclosureContributing: BoundDevice {
    func accumulateTransientPhysicalResidualEnclosure(
        state: SolutionState, integration: IntegrationState,
        add: (Int, CompensatedValue, Double) -> Void
    ) throws
}

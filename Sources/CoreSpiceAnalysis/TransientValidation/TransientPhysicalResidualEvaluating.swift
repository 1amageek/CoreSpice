import CoreSpiceDevices

/// Supplies original transient equations without reconstructing them from a linearized RHS.
public protocol TransientPhysicalResidualEvaluating: TransientPhysicalResidualValidating {
    func accumulateResidual(
        state: SolutionState, integration: IntegrationState, add: (Int, Double) -> Void
    ) throws
}

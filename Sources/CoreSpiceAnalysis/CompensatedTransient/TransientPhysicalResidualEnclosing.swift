import CoreSpiceDevices

/// Encloses complete original F+Iq equations using immutable accepted histories.
public protocol TransientPhysicalResidualEnclosing: TransientPhysicalResidualValidating {
    func accumulateResidualEnclosure(
        state: SolutionState, integration: IntegrationState,
        add: (Int, CompensatedValue, Double) -> Void
    ) throws
}

import CoreSpiceDevices

/// Validates original transient equations before accepted device history changes.
public protocol TransientPhysicalResidualValidating: Sendable {
    func validate(state: SolutionState, integration: IntegrationState) throws
}

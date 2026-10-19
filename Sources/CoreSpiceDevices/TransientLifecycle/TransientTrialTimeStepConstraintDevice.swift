/// A device whose freshly evaluated candidate can limit the current interval.
public protocol TransientTrialTimeStepConstraintDevice: BoundDevice {
    /// Returns nil for no bound, or a finite positive bound in seconds.
    /// This query must not publish accepted device history.
    func maximumTransientTimeStep(state: SolutionState, integration: IntegrationState) throws -> Double?
}

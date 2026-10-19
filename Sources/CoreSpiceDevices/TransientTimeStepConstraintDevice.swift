/// A device that imposes an upper bound on transient-analysis timesteps.
///
/// Delay-based devices use this contract to ensure that every requested
/// history value is available from an already accepted solution.
public protocol TransientTimeStepConstraintDevice: BoundDevice {
    /// Accepted-state limit in seconds, reread before each step. Positive infinity means no bound.
    var maximumTransientTimeStep: Double { get }
}

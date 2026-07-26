/// A device that imposes an upper bound on transient-analysis timesteps.
///
/// Delay-based devices use this contract to ensure that every requested
/// history value is available from an already accepted solution.
public protocol TransientTimeStepConstraintDevice: BoundDevice {
    var maximumTransientTimeStep: Double { get }
}

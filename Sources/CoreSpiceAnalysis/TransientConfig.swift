import CoreSpiceDevices

/// Configuration parameters for transient (time-domain) analysis.
///
/// Controls the simulation time span, timestep limits, integration
/// method, and local truncation error (LTE) tolerance.
public struct TransientConfig: Sendable {

    /// Simulation end time (seconds).
    public var stopTime: Double

    /// Maximum allowed timestep (seconds).
    public var maxTimeStep: Double

    /// Initial timestep, or `nil` to auto-compute from `maxTimeStep`.
    public var initialTimeStep: Double?

    /// Minimum allowed timestep (seconds). The simulation fails if the
    /// adaptive controller tries to go below this value.
    public var minTimeStep: Double

    /// Integration method to use for the first step.
    /// Subsequent steps may switch to a higher-order method.
    public var initialMethod: IntegrationMethod

    /// Local truncation error tolerance.
    public var lteTolerance: Double

    /// Maximum number of timestep reductions before declaring failure.
    public var maxTimeStepReductions: Int

    /// Factor by which the timestep is multiplied when a step is rejected.
    public var shrinkFactor: Double

    /// When `true`, skip the DC operating point at t=0 and use device
    /// initial conditions (`.ic` / UIC) to build the starting solution.
    public var useInitialConditions: Bool

    public init(
        stopTime: Double,
        maxTimeStep: Double? = nil,
        initialTimeStep: Double? = nil,
        minTimeStep: Double = 1e-18,
        initialMethod: IntegrationMethod = .backwardEuler,
        lteTolerance: Double = 1e-4,
        maxTimeStepReductions: Int = 30,
        shrinkFactor: Double = 0.5,
        useInitialConditions: Bool = false
    ) {
        self.stopTime = stopTime
        self.maxTimeStep = maxTimeStep ?? stopTime / 50.0
        self.initialTimeStep = initialTimeStep
        self.minTimeStep = minTimeStep
        self.initialMethod = initialMethod
        self.lteTolerance = lteTolerance
        self.maxTimeStepReductions = maxTimeStepReductions
        self.shrinkFactor = shrinkFactor
        self.useInitialConditions = useInitialConditions
    }
}

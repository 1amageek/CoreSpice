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

    /// Normalized LTE tolerance (dimensionless).
    /// After normalization, 1.0 means every variable is at its tolerance boundary.
    public var lteTolerance: Double

    /// Maximum number of timestep reductions before declaring failure.
    public var maxTimeStepReductions: Int

    /// Factor by which the timestep is multiplied when a step is rejected.
    public var shrinkFactor: Double

    /// When `true`, skip the DC operating point at t=0 and use device
    /// initial conditions (`.ic` / UIC) to build the starting solution.
    public var useInitialConditions: Bool

    /// Number of consecutive timestep reductions before attempting GMIN stepping.
    /// Set to `Int.max` to disable GMIN stepping in transient.
    public var gminSteppingThreshold: Int

    /// GMIN stepping configuration for transient convergence assistance.
    public var gminStepping: GminStepping

    public init(
        stopTime: Double,
        maxTimeStep: Double? = nil,
        initialTimeStep: Double? = nil,
        minTimeStep: Double = 1e-18,
        initialMethod: IntegrationMethod = .backwardEuler,
        lteTolerance: Double = 1.0,
        maxTimeStepReductions: Int = 30,
        shrinkFactor: Double = 0.5,
        useInitialConditions: Bool = false,
        gminSteppingThreshold: Int = 5,
        gminStepping: GminStepping = GminStepping(
            initialGmin: 1e-3,
            finalGmin: 1e-12,
            reductionFactor: 10.0,
            maxSteps: 5
        )
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
        self.gminSteppingThreshold = gminSteppingThreshold
        self.gminStepping = gminStepping
    }

    public func validate() throws {
        try validatePositiveFinite(stopTime, name: "stopTime")
        try validatePositiveFinite(maxTimeStep, name: "maxTimeStep")
        try validatePositiveFinite(minTimeStep, name: "minTimeStep")
        if let initialTimeStep {
            try validatePositiveFinite(initialTimeStep, name: "initialTimeStep")
        }
        try validatePositiveFinite(lteTolerance, name: "lteTolerance")

        guard minTimeStep <= maxTimeStep else {
            throw AnalysisError.invalidConfiguration(
                "minTimeStep must be less than or equal to maxTimeStep."
            )
        }
        guard maxTimeStepReductions >= 0 else {
            throw AnalysisError.invalidConfiguration(
                "maxTimeStepReductions must be greater than or equal to zero."
            )
        }
        guard shrinkFactor > 0, shrinkFactor < 1, shrinkFactor.isFinite else {
            throw AnalysisError.invalidConfiguration(
                "shrinkFactor must be finite and in the open interval (0, 1)."
            )
        }
        guard gminSteppingThreshold > 0 else {
            throw AnalysisError.invalidConfiguration(
                "gminSteppingThreshold must be greater than zero."
            )
        }

        try validateGminStepping()
    }

    public func effectiveInitialTimeStep() throws -> Double {
        try validate()
        return max(initialTimeStep ?? (maxTimeStep / 10.0), minTimeStep)
    }

    private func validatePositiveFinite(_ value: Double, name: String) throws {
        guard value > 0, value.isFinite else {
            throw AnalysisError.invalidConfiguration(
                "\(name) must be finite and greater than zero."
            )
        }
    }

    private func validateGminStepping() throws {
        guard gminStepping.initialGmin > 0, gminStepping.initialGmin.isFinite else {
            throw AnalysisError.invalidConfiguration(
                "gminStepping.initialGmin must be finite and greater than zero."
            )
        }
        guard gminStepping.finalGmin >= 0, gminStepping.finalGmin.isFinite else {
            throw AnalysisError.invalidConfiguration(
                "gminStepping.finalGmin must be finite and greater than or equal to zero."
            )
        }
        guard gminStepping.initialGmin >= gminStepping.finalGmin else {
            throw AnalysisError.invalidConfiguration(
                "gminStepping.initialGmin must be greater than or equal to finalGmin."
            )
        }
        guard gminStepping.reductionFactor > 1, gminStepping.reductionFactor.isFinite else {
            throw AnalysisError.invalidConfiguration(
                "gminStepping.reductionFactor must be finite and greater than one."
            )
        }
        guard gminStepping.maxSteps > 0 else {
            throw AnalysisError.invalidConfiguration(
                "gminStepping.maxSteps must be greater than zero."
            )
        }
    }
}

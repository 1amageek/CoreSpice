import CoreSpiceIR

/// A device instance that has been bound to specific matrix indices.
///
/// Bound devices contribute their element equations to the MNA
/// system through the various `stamp` methods, one per analysis type.
public protocol BoundDevice: Sendable {
    /// The original instance this device was created from.
    var instance: Instance { get }

    /// Stamp the device's DC operating-point equations.
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState)

    /// Stamp the device's AC small-signal model.
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double)

    /// Stamp the device's transient companion model.
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState)

    /// Check whether the device has converged between Newton iterations.
    func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult

    /// Return waveform breakpoints within the given time interval.
    ///
    /// Breakpoints are times where the waveform has discontinuities
    /// (e.g., pulse edges) that require precise timestep placement.
    func breakpoints(in interval: ClosedRange<Double>) -> [Double]
}

// Default implementation for devices without time-varying waveforms
extension BoundDevice {
    public func breakpoints(in interval: ClosedRange<Double>) -> [Double] {
        return []
    }
}

/// A device that has initial conditions for transient analysis.
public protocol InitialConditionDevice: BoundDevice {
    /// Whether this device has explicit initial conditions set.
    var hasInitialCondition: Bool { get }
}

/// A device with an initial voltage condition.
public protocol VoltageInitialConditionDevice: InitialConditionDevice {
    /// The initial voltage across the device.
    var initialVoltage: Double { get }
    /// The positive node of the device.
    var positiveNode: Node { get }
    /// The negative node of the device.
    var negativeNode: Node { get }
}

/// A device with an initial current condition.
public protocol CurrentInitialConditionDevice: InitialConditionDevice {
    /// The initial current through the device.
    var initialCurrent: Double { get }
    /// The branch variable for the device current.
    var deviceBranch: Branch { get }
}

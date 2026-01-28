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
}

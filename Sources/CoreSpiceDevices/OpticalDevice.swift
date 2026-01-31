import CoreSpiceIR

/// A purely optical device with no electrical ports.
///
/// Optical devices participate only in the optical signal network,
/// not in the MNA electrical system. They propagate optical signals
/// from input nodes to output nodes and provide linear transfer
/// coefficients for automatic sensitivity propagation.
///
/// The base `BoundDevice` stamp methods are implemented as no-ops
/// since these devices have no electrical contribution.
///
/// Examples: waveguide, splitter, combiner, optical filter.
public protocol OpticalDevice: BoundDevice {

    /// Optical nodes that this device reads from.
    var opticalInputNodes: [OpticalNode] { get }

    /// Optical nodes that this device writes to.
    var opticalOutputNodes: [OpticalNode] { get }

    /// Propagates optical signals from input nodes to output nodes.
    ///
    /// Called by `OpticalNetworkEvaluator` during DAG traversal.
    /// The implementation should apply the device's transfer function
    /// (attenuation, phase rotation, splitting, etc.) to the input signals.
    func propagate(inputs: [OpticalNode: OpticalSignal]) -> [OpticalNode: OpticalSignal]

    /// Returns the linear power transfer coefficients between input and output nodes.
    ///
    /// Used by `OpticalNetworkEvaluator` for automatic sensitivity propagation:
    ///     dP_out/dV = coefficient × dP_in/dV
    ///
    /// For scalar links (waveguide): one entry `(in, out, T)`.
    /// For MIMO devices (2×2 coupler): up to N×M entries.
    func transferCoefficients() -> [OpticalTransferEntry]
}

// MARK: - Default BoundDevice Implementations (No-ops)

extension OpticalDevice {

    /// No electrical contribution.
    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {}

    /// No electrical contribution.
    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {}

    /// No electrical contribution.
    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {}

    /// Purely optical devices always converge from the electrical perspective.
    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        .converged
    }
}

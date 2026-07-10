import CoreSpiceIR

/// A device that bridges the electrical and optical domains.
///
/// Optoelectronic devices participate in both the MNA electrical system
/// and the optical signal network. They implement optical-aware stamp
/// methods that receive the current `OpticalState` (including sensitivities)
/// and can contribute both:
/// - Standard electrical stamps (conductance, current sources)
/// - Jacobian entries from optical-to-electrical coupling (`gm_opto`)
///
/// Examples: photodiode, LED, laser diode, electro-optic modulator.
///
/// The protocol extends `BoundDevice` and provides default implementations
/// of the base stamp methods that delegate to the optical-aware versions
/// with an empty `OpticalState`. This defines electrical-only execution for
/// contexts that intentionally do not provide an optical network.
public protocol OptoelectronicDevice: BoundDevice {

    /// Optical nodes that this device reads from.
    var opticalInputNodes: [OpticalNode] { get }

    /// Optical nodes that this device writes to.
    var opticalOutputNodes: [OpticalNode] { get }

    /// Computes the optical output signals from the current electrical state.
    ///
    /// Called by `OpticalNetworkEvaluator` during DAG traversal for
    /// devices that emit light (laser diodes, LEDs).
    /// Devices that only receive light (photodiodes) return an empty dictionary.
    func computeOpticalOutput(
        electricalState: SolutionState,
        opticalState: OpticalState
    ) -> [OpticalNode: OpticalSignal]

    /// Stamps the DC operating-point equations including optical coupling.
    ///
    /// Must include:
    /// 1. Standard electrical I-V linearization
    /// 2. Photocurrent source (for receivers)
    /// 3. `gm_opto` Jacobian entries from `opticalState.sensitivities`
    func stampDC(into stamper: inout MatrixStamper, state: SolutionState, opticalState: OpticalState)

    /// Stamps the AC small-signal model including optical transfer chain.
    func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, opticalState: OpticalState, omega: Double)

    /// Stamps the transient companion model including optical coupling.
    func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, opticalState: OpticalState, integration: IntegrationState)

    /// Checks convergence including optical state.
    func checkConvergence(
        state: SolutionState, previousState: SolutionState,
        opticalState: OpticalState, previousOpticalState: OpticalState
    ) -> ConvergenceResult

    /// Returns noise sources including optical-domain noise.
    ///
    /// Photodiode: shot noise `2q(I_photo + I_dark)`
    /// Laser: RIN-induced current noise at the receiver
    func noiseContributions(
        state: SolutionState,
        opticalState: OpticalState,
        frequency: Double
    ) -> [NoiseSource]
}

// MARK: - Default Implementations

extension OptoelectronicDevice {

    /// Default: no optical output (for receivers like photodiodes).
    public func computeOpticalOutput(
        electricalState: SolutionState,
        opticalState: OpticalState
    ) -> [OpticalNode: OpticalSignal] {
        [:]
    }

    /// Default: delegates to optical-aware stampDC with empty OpticalState.
    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        stampDC(into: &stamper, state: state, opticalState: OpticalState())
    }

    /// Default: delegates to optical-aware stampAC with empty OpticalState.
    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        stampAC(into: &stamper, state: state, opticalState: OpticalState(), omega: omega)
    }

    /// Default: delegates to optical-aware stampTransient with empty OpticalState.
    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        stampTransient(into: &stamper, state: state, opticalState: OpticalState(), integration: integration)
    }

    /// Default: delegates to optical-aware checkConvergence with empty OpticalState.
    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        checkConvergence(
            state: state, previousState: previousState,
            opticalState: OpticalState(), previousOpticalState: OpticalState()
        )
    }

    /// Default: no optical noise contributions.
    public func noiseContributions(
        state: SolutionState,
        opticalState: OpticalState,
        frequency: Double
    ) -> [NoiseSource] {
        []
    }
}

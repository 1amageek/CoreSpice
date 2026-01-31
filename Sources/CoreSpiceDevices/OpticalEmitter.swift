import CoreSpiceIR

/// An optoelectronic device that emits light, providing both
/// optical output values and their sensitivities to electrical variables.
///
/// The sensitivity information enables the `OpticalNetworkEvaluator`
/// to perform forward-mode sensitivity propagation through the optical DAG,
/// which is essential for correct NR Jacobian construction.
///
/// Devices conforming to this protocol: laser diode, LED.
public protocol OpticalEmitter: OptoelectronicDevice {

    /// Computes optical output signals along with their local sensitivities
    /// to electrical variables.
    ///
    /// - Returns: A tuple of:
    ///   - `signals`: Optical output signals at each output node
    ///   - `sensitivities`: Local derivatives `dP_out/dV_j` for each
    ///     (optical output node, electrical variable index) pair
    ///
    /// Example for a laser diode:
    /// ```
    /// signals: [optical_out: OpticalSignal(power = P)]
    /// sensitivities: [
    ///     (opticalNodeId: out.id, electricalVarIndex: anodeIdx, dPdV: dP/dI × dI/dV_a),
    ///     (opticalNodeId: out.id, electricalVarIndex: cathodeIdx, dPdV: dP/dI × dI/dV_c)
    /// ]
    /// ```
    func computeOpticalOutputWithSensitivity(
        electricalState: SolutionState,
        opticalState: OpticalState
    ) -> (
        signals: [OpticalNode: OpticalSignal],
        sensitivities: [(opticalNodeId: Int, electricalVarIndex: Int, dPdV: Double)]
    )
}

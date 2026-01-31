/// Device protocol for Newton-Raphson voltage limiting.
///
/// PN junctions and MOSFETs have exponential or strongly nonlinear I-V
/// characteristics that can cause the NR solver to overshoot and diverge.
/// Devices conforming to this protocol clamp the solution vector between
/// NR iterations, keeping terminal voltages within a physically reasonable
/// range.
///
/// Interface Segregation: linear devices (R, C, L, V/I sources) do not
/// need voltage limiting and should not conform.
public protocol VoltageLimitingDevice: BoundDevice {
    /// Limits terminal voltages in the solution vector after an NR update.
    ///
    /// Called after the NR linear solve and damping but before convergence
    /// checking. Implementations modify `solution` in place, clamping
    /// voltages that would cause numerical overflow or divergence.
    ///
    /// - Parameters:
    ///   - solution: The current NR solution vector (modified in place).
    ///   - previousSolution: The solution vector from the previous NR iteration.
    func limitVoltages(solution: inout [Double], previousSolution: [Double])
}

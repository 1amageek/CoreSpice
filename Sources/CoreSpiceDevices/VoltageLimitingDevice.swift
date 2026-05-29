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

    /// Whether limiting must also run on the first NR iteration (from the zero
    /// initial guess). Exponential PN junctions set this true: without it, a
    /// junction driven by a current source jumps to an enormous voltage on the
    /// first step and cannot recover. Polynomial devices (MOSFETs) leave it
    /// false so the first step can reach the operating region freely.
    var limitsFirstIteration: Bool { get }
}

public extension VoltageLimitingDevice {
    /// Default: do not limit on the first iteration (suits polynomial devices).
    var limitsFirstIteration: Bool { false }
}

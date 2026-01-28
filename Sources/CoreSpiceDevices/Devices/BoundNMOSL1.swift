import Foundation
import CoreSpiceIR

/// An NMOS Level 1 MOSFET bound to circuit nodes.
///
/// Implements the Shichman-Hodges model with three operating regions:
/// - **Cutoff**: `Vgs < Vth` -- no current flows.
/// - **Linear (triode)**: `Vgs >= Vth` and `Vds < Vgs - Vth`.
/// - **Saturation**: `Vgs >= Vth` and `Vds >= Vgs - Vth`.
///
/// The device is linearised around the current operating point for
/// Newton-Raphson iteration.
public struct BoundNMOSL1: BoundDevice, Sendable {

    public let instance: Instance
    private let drain: Node
    private let gate: Node
    private let source: Node
    private let parameters: MOSFETModelParameters

    /// Convergence tolerance for terminal voltages (V).
    private static let voltageTolerance: Double = 1e-6

    init(
        instance: Instance,
        drain: Node,
        gate: Node,
        source: Node,
        parameters: MOSFETModelParameters
    ) {
        self.instance = instance
        self.drain = drain
        self.gate = gate
        self.source = source
        self.parameters = parameters
    }

    // MARK: - BoundDevice

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        let op = operatingPoint(state: state)
        stampLinearized(into: &stamper, op: op)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        // Small-signal model: stamp gm and gds
        let op = operatingPoint(state: state)
        let dIdx = stamper.nodeIndex(drain)
        let gIdx = stamper.nodeIndex(gate)
        let sIdx = stamper.nodeIndex(source)

        // gds: drain-source conductance
        if op.gds != 0 {
            if let dIdx {
                stamper.stampMatrix(dIdx, dIdx, op.gds, 0.0)
            }
            if let sIdx {
                stamper.stampMatrix(sIdx, sIdx, op.gds, 0.0)
            }
            if let dIdx, let sIdx {
                stamper.stampMatrix(dIdx, sIdx, -op.gds, 0.0)
                stamper.stampMatrix(sIdx, dIdx, -op.gds, 0.0)
            }
        }

        // gm: transconductance (gate controls drain current)
        // Id += gm * Vgs => stamp gm from gate to drain-source
        if op.gm != 0 {
            if let dIdx, let gIdx {
                stamper.stampMatrix(dIdx, gIdx, op.gm, 0.0)
            }
            if let dIdx, let sIdx {
                stamper.stampMatrix(dIdx, sIdx, -op.gm, 0.0)
            }
            if let sIdx, let gIdx {
                stamper.stampMatrix(sIdx, gIdx, -op.gm, 0.0)
            }
            if let sIdx {
                stamper.stampMatrix(sIdx, sIdx, op.gm, 0.0)
            }
        }
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        // For Level 1 without parasitic capacitances, transient stamp
        // is the same as DC (quasi-static approximation).
        stampDC(into: &stamper, state: state)
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        let vgsNew = state.voltage(at: gate) - state.voltage(at: source)
        let vgsOld = previousState.voltage(at: gate) - previousState.voltage(at: source)
        let vdsNew = state.voltage(at: drain) - state.voltage(at: source)
        let vdsOld = previousState.voltage(at: drain) - previousState.voltage(at: source)

        let deltaVgs = abs(vgsNew - vgsOld)
        let deltaVds = abs(vdsNew - vdsOld)
        let maxDelta = max(deltaVgs, deltaVds)

        if maxDelta < Self.voltageTolerance {
            return .converged
        }
        return .notConverged(maxDelta: maxDelta, deviceName: instance.name)
    }

    // MARK: - Internal Model

    private struct OperatingPointResult {
        let ids: Double   // drain-source current
        let gm: Double    // transconductance dIds/dVgs
        let gds: Double   // output conductance dIds/dVds
        let vgs: Double
        let vds: Double
    }

    private func operatingPoint(state: SolutionState) -> OperatingPointResult {
        let vgs = state.voltage(at: gate) - state.voltage(at: source)
        let vds = state.voltage(at: drain) - state.voltage(at: source)
        let vth = parameters.vto
        let beta = parameters.beta
        let lambda = parameters.lambda

        if vgs < vth {
            // Cutoff
            return OperatingPointResult(ids: 0, gm: 0, gds: 0, vgs: vgs, vds: vds)
        }

        let vgst = vgs - vth

        if vds < vgst {
            // Linear region: Ids = beta * (Vgst * Vds - 0.5 * Vds^2) * (1 + lambda * Vds)
            let ids = beta * (vgst * vds - 0.5 * vds * vds) * (1.0 + lambda * vds)
            let gm = beta * vds * (1.0 + lambda * vds)
            let gds = beta * (vgst - vds) * (1.0 + lambda * vds)
                    + beta * (vgst * vds - 0.5 * vds * vds) * lambda
            return OperatingPointResult(ids: ids, gm: gm, gds: gds, vgs: vgs, vds: vds)
        } else {
            // Saturation region: Ids = 0.5 * beta * Vgst^2 * (1 + lambda * Vds)
            let ids = 0.5 * beta * vgst * vgst * (1.0 + lambda * vds)
            let gm = beta * vgst * (1.0 + lambda * vds)
            let gds = 0.5 * beta * vgst * vgst * lambda
            return OperatingPointResult(ids: ids, gm: gm, gds: gds, vgs: vgs, vds: vds)
        }
    }

    /// Stamp the linearised model around the operating point.
    ///
    /// The Newton-Raphson linearisation gives:
    ///   `I_stamp = Ids0 + gm * (Vgs - Vgs0) + gds * (Vds - Vds0)`
    ///   `       = gm * Vgs + gds * Vds + (Ids0 - gm*Vgs0 - gds*Vds0)`
    ///
    /// The last term is the equivalent current source (RHS).
    private func stampLinearized(into stamper: inout MatrixStamper, op: OperatingPointResult) {
        let dIdx = stamper.nodeIndex(drain)
        let gIdx = stamper.nodeIndex(gate)
        let sIdx = stamper.nodeIndex(source)

        // Conductance stamps: gds between drain and source
        if op.gds != 0 {
            if let dIdx {
                stamper.stampMatrix(dIdx, dIdx, op.gds)
            }
            if let sIdx {
                stamper.stampMatrix(sIdx, sIdx, op.gds)
            }
            if let dIdx, let sIdx {
                stamper.stampMatrix(dIdx, sIdx, -op.gds)
                stamper.stampMatrix(sIdx, dIdx, -op.gds)
            }
        }

        // Transconductance stamps: gm contribution from gate-source voltage
        if op.gm != 0 {
            if let dIdx, let gIdx {
                stamper.stampMatrix(dIdx, gIdx, op.gm)
            }
            if let dIdx, let sIdx {
                stamper.stampMatrix(dIdx, sIdx, -op.gm)
            }
            if let sIdx, let gIdx {
                stamper.stampMatrix(sIdx, gIdx, -op.gm)
            }
            if let sIdx {
                stamper.stampMatrix(sIdx, sIdx, op.gm)
            }
        }

        // Equivalent current source: Ieq = Ids - gm*Vgs - gds*Vds
        let ieq = op.ids - op.gm * op.vgs - op.gds * op.vds

        if let dIdx {
            stamper.stampRHS(dIdx, ieq)
        }
        if let sIdx {
            stamper.stampRHS(sIdx, -ieq)
        }
    }
}

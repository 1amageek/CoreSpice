import Foundation
import CoreSpiceIR

/// A PMOS Level 1 MOSFET bound to circuit nodes.
///
/// Implements the Shichman-Hodges model with reversed polarities
/// compared to the NMOS device. The PMOS conducts when `Vsg > |Vtp|`
/// (equivalently `Vgs < Vtp` where Vtp is negative).
///
/// Operating regions (using source-referenced voltages):
/// - **Cutoff**: `Vsg < |Vtp|` -- no current flows.
/// - **Linear**: `Vsg >= |Vtp|` and `Vsd < Vsg - |Vtp|`.
/// - **Saturation**: `Vsg >= |Vtp|` and `Vsd >= Vsg - |Vtp|`.
///
/// Current flows from source to drain (conventional direction).
public struct BoundPMOSL1: BoundDevice, Sendable {

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
        let op = operatingPoint(state: state)
        let dIdx = stamper.nodeIndex(drain)
        let gIdx = stamper.nodeIndex(gate)
        let sIdx = stamper.nodeIndex(source)

        // gds: drain-source conductance (current from source to drain)
        // For PMOS, Isd > 0 so stamp as source-to-drain
        if op.gds != 0 {
            if let sIdx {
                stamper.stampMatrix(sIdx, sIdx, op.gds, 0.0)
            }
            if let dIdx {
                stamper.stampMatrix(dIdx, dIdx, op.gds, 0.0)
            }
            if let sIdx, let dIdx {
                stamper.stampMatrix(sIdx, dIdx, -op.gds, 0.0)
                stamper.stampMatrix(dIdx, sIdx, -op.gds, 0.0)
            }
        }

        // gm: transconductance (Vsg controls Isd)
        // Isd += gm * delta_Vsg = gm * (Vs - Vg)
        if op.gm != 0 {
            if let sIdx {
                stamper.stampMatrix(sIdx, sIdx, op.gm, 0.0)
            }
            if let sIdx, let gIdx {
                stamper.stampMatrix(sIdx, gIdx, -op.gm, 0.0)
            }
            if let dIdx, let gIdx {
                stamper.stampMatrix(dIdx, gIdx, op.gm, 0.0)
            }
            if let dIdx, let sIdx {
                stamper.stampMatrix(dIdx, sIdx, -op.gm, 0.0)
            }
        }
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        stampDC(into: &stamper, state: state)
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        let vsgNew = state.voltage(at: source) - state.voltage(at: gate)
        let vsgOld = previousState.voltage(at: source) - previousState.voltage(at: gate)
        let vsdNew = state.voltage(at: source) - state.voltage(at: drain)
        let vsdOld = previousState.voltage(at: source) - previousState.voltage(at: drain)

        let deltaVsg = abs(vsgNew - vsgOld)
        let deltaVsd = abs(vsdNew - vsdOld)
        let maxDelta = max(deltaVsg, deltaVsd)

        if maxDelta < Self.voltageTolerance {
            return .converged
        }
        return .notConverged(maxDelta: maxDelta, deviceName: instance.name)
    }

    // MARK: - Internal Model

    private struct OperatingPointResult {
        let isd: Double   // source-to-drain current (positive when PMOS is on)
        let gm: Double    // transconductance dIsd/dVsg
        let gds: Double   // output conductance dIsd/dVsd
        let vsg: Double
        let vsd: Double
    }

    private func operatingPoint(state: SolutionState) -> OperatingPointResult {
        // PMOS uses source-gate and source-drain voltages
        let vsg = state.voltage(at: source) - state.voltage(at: gate)
        let vsd = state.voltage(at: source) - state.voltage(at: drain)

        // Vtp is stored as negative, so |Vtp| = -vto
        let vtpAbs = -parameters.vto
        let beta = parameters.beta
        let lambda = parameters.lambda

        if vsg < vtpAbs {
            // Cutoff
            return OperatingPointResult(isd: 0, gm: 0, gds: 0, vsg: vsg, vsd: vsd)
        }

        let vsgOverdrive = vsg - vtpAbs

        if vsd < vsgOverdrive {
            // Linear region: Isd = beta * (Vov * Vsd - 0.5 * Vsd^2) * (1 + lambda * Vsd)
            let isd = beta * (vsgOverdrive * vsd - 0.5 * vsd * vsd) * (1.0 + lambda * vsd)
            let gm = beta * vsd * (1.0 + lambda * vsd)
            let gds = beta * (vsgOverdrive - vsd) * (1.0 + lambda * vsd)
                    + beta * (vsgOverdrive * vsd - 0.5 * vsd * vsd) * lambda
            return OperatingPointResult(isd: isd, gm: gm, gds: gds, vsg: vsg, vsd: vsd)
        } else {
            // Saturation region: Isd = 0.5 * beta * Vov^2 * (1 + lambda * Vsd)
            let isd = 0.5 * beta * vsgOverdrive * vsgOverdrive * (1.0 + lambda * vsd)
            let gm = beta * vsgOverdrive * (1.0 + lambda * vsd)
            let gds = 0.5 * beta * vsgOverdrive * vsgOverdrive * lambda
            return OperatingPointResult(isd: isd, gm: gm, gds: gds, vsg: vsg, vsd: vsd)
        }
    }

    /// Stamp the linearised PMOS model around the operating point.
    ///
    /// Current flows from source to drain:
    ///   `I_stamp = Isd0 + gm * (Vsg - Vsg0) + gds * (Vsd - Vsd0)`
    ///   `       = gm * Vsg + gds * Vsd + (Isd0 - gm*Vsg0 - gds*Vsd0)`
    private func stampLinearized(into stamper: inout MatrixStamper, op: OperatingPointResult) {
        let dIdx = stamper.nodeIndex(drain)
        let gIdx = stamper.nodeIndex(gate)
        let sIdx = stamper.nodeIndex(source)

        // Conductance stamps: gds between source and drain
        // Current leaves source, enters drain
        if op.gds != 0 {
            if let sIdx {
                stamper.stampMatrix(sIdx, sIdx, op.gds)
            }
            if let dIdx {
                stamper.stampMatrix(dIdx, dIdx, op.gds)
            }
            if let sIdx, let dIdx {
                stamper.stampMatrix(sIdx, dIdx, -op.gds)
                stamper.stampMatrix(dIdx, sIdx, -op.gds)
            }
        }

        // Transconductance stamps: gm from Vsg
        // Isd += gm * Vsg = gm * (Vs - Vg)
        // Current leaves source node, enters drain node
        if op.gm != 0 {
            if let sIdx {
                stamper.stampMatrix(sIdx, sIdx, op.gm)
            }
            if let sIdx, let gIdx {
                stamper.stampMatrix(sIdx, gIdx, -op.gm)
            }
            if let dIdx, let gIdx {
                stamper.stampMatrix(dIdx, gIdx, op.gm)
            }
            if let dIdx, let sIdx {
                stamper.stampMatrix(dIdx, sIdx, -op.gm)
            }
        }

        // Equivalent current source: Ieq = Isd - gm*Vsg - gds*Vsd
        // Positive Ieq means current from source to drain
        let ieq = op.isd - op.gm * op.vsg - op.gds * op.vsd

        // Current leaves source (negative contribution) and enters drain (positive)
        if let sIdx {
            stamper.stampRHS(sIdx, -ieq)
        }
        if let dIdx {
            stamper.stampRHS(dIdx, ieq)
        }
    }
}

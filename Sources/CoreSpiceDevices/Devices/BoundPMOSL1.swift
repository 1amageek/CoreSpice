import Foundation
import CoreSpiceIR

/// A PMOS Level 1 MOSFET bound to circuit nodes.
///
/// Implements the Shichman-Hodges model with reversed polarities
/// compared to the NMOS device. The PMOS conducts when `Vsg > |Vtp|`
/// (equivalently `Vgs < Vtp` where Vtp is negative).
///
/// Body effect modulates the threshold voltage via the bulk-source voltage:
///   `Vth = Vto + gamma * (sqrt(2*phi - Vbs) - sqrt(2*phi))`
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
    private let bulk: Node
    private let parameters: MOSFETModelParameters

    /// Convergence tolerance for terminal voltages (V).
    private static let voltageTolerance: Double = 1e-6

    init(
        instance: Instance,
        drain: Node,
        gate: Node,
        source: Node,
        bulk: Node,
        parameters: MOSFETModelParameters
    ) {
        self.instance = instance
        self.drain = drain
        self.gate = gate
        self.source = source
        self.bulk = bulk
        self.parameters = parameters
    }

    // MARK: - BoundDevice

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        let op = operatingPoint(state: state)
        stampLinearized(into: &stamper, op: op)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        let op = operatingPoint(state: state)
        let effectiveDrain = op.reversed ? source : drain
        let effectiveSource = op.reversed ? drain : source
        let dIdx = stamper.nodeIndex(effectiveDrain)
        let gIdx = stamper.nodeIndex(gate)
        let sIdx = stamper.nodeIndex(effectiveSource)
        let bIdx = stamper.nodeIndex(bulk)

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

        // gmbs: body transconductance (Vbs modulates threshold)
        // Isd += gmbs * delta_Vbs = gmbs * (Vb - Vs)
        // Note: for PMOS, Vbs = V(bulk) - V(source). Increasing Vbs (bulk more positive
        // than source) reduces |Vtp|, increasing Isd. gmbs is positive.
        // Stamp: current from source, controlled by (Vb - Vs)
        if op.gmbs != 0 {
            if let sIdx, let bIdx {
                stamper.stampMatrix(sIdx, bIdx, -op.gmbs, 0.0)
            }
            if let sIdx {
                stamper.stampMatrix(sIdx, sIdx, op.gmbs, 0.0)
            }
            if let dIdx, let bIdx {
                stamper.stampMatrix(dIdx, bIdx, op.gmbs, 0.0)
            }
            if let dIdx, let sIdx {
                stamper.stampMatrix(dIdx, sIdx, -op.gmbs, 0.0)
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
        let vbsNew = state.voltage(at: bulk) - state.voltage(at: source)
        let vbsOld = previousState.voltage(at: bulk) - previousState.voltage(at: source)

        let deltaVsg = abs(vsgNew - vsgOld)
        let deltaVsd = abs(vsdNew - vsdOld)
        let deltaVbs = abs(vbsNew - vbsOld)
        let maxDelta = max(deltaVsg, max(deltaVsd, deltaVbs))

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
        let gmbs: Double  // body transconductance dIsd/dVbs
        let vsg: Double
        let vsd: Double
        let vbs: Double
        let reversed: Bool // true when source and drain are swapped (Vsd < 0)
    }

    private func operatingPoint(state: SolutionState) -> OperatingPointResult {
        // PMOS uses source-gate and source-drain voltages
        let rawVsg = state.voltage(at: source) - state.voltage(at: gate)
        let rawVsd = state.voltage(at: source) - state.voltage(at: drain)
        let rawVbs = state.voltage(at: bulk) - state.voltage(at: source)

        let beta = parameters.beta
        let lambda = parameters.lambda

        // PMOS is symmetric: when Vsd < 0, swap source and drain
        let reversed = rawVsd < 0
        let vsg: Double
        let vsd: Double
        let vbs: Double
        if reversed {
            vsd = -rawVsd
            vsg = state.voltage(at: drain) - state.voltage(at: gate)
            vbs = state.voltage(at: bulk) - state.voltage(at: drain)
        } else {
            vsd = rawVsd
            vsg = rawVsg
            vbs = rawVbs
        }

        // Body effect: threshold voltage modulation
        // Vtp = VTO + gamma * (sqrt(2*phi - Vbs) - sqrt(2*phi))
        // For PMOS, VTO < 0, and |Vtp| = -Vtp
        let twoPhi = 2.0 * parameters.phi
        let sqrtTwoPhi = sqrt(abs(twoPhi))
        let twoPhiMinusVbs = max(twoPhi - vbs, 0.01)
        let vtp = parameters.vto + parameters.gamma * (sqrt(twoPhiMinusVbs) - sqrtTwoPhi)
        // |Vtp| for the conduction check
        let vtpAbs = -vtp

        if vsg < vtpAbs {
            // Cutoff
            return OperatingPointResult(
                isd: 0, gm: 0, gds: 0, gmbs: 0,
                vsg: rawVsg, vsd: rawVsd, vbs: rawVbs, reversed: reversed
            )
        }

        let vsgOverdrive = vsg - vtpAbs

        let isd: Double
        let gm: Double
        let gds: Double

        if vsd < vsgOverdrive {
            // Linear region: Isd = beta * (Vov * Vsd - 0.5 * Vsd^2) * (1 + lambda * Vsd)
            isd = beta * (vsgOverdrive * vsd - 0.5 * vsd * vsd) * (1.0 + lambda * vsd)
            gm = beta * vsd * (1.0 + lambda * vsd)
            gds = beta * (vsgOverdrive - vsd) * (1.0 + lambda * vsd)
                    + beta * (vsgOverdrive * vsd - 0.5 * vsd * vsd) * lambda
        } else {
            // Saturation region: Isd = 0.5 * beta * Vov^2 * (1 + lambda * Vsd)
            isd = 0.5 * beta * vsgOverdrive * vsgOverdrive * (1.0 + lambda * vsd)
            gm = beta * vsgOverdrive * (1.0 + lambda * vsd)
            gds = 0.5 * beta * vsgOverdrive * vsgOverdrive * lambda
        }

        // Body transconductance: gmbs = gm * gamma / (2 * sqrt(2*phi - Vbs))
        let gmbs: Double
        if parameters.gamma > 0 {
            gmbs = gm * parameters.gamma / (2.0 * sqrt(twoPhiMinusVbs))
        } else {
            gmbs = 0
        }

        if reversed {
            // When reversed, current flows in opposite direction relative to terminal labels
            return OperatingPointResult(
                isd: -isd, gm: gm, gds: gds, gmbs: gmbs,
                vsg: rawVsg, vsd: rawVsd, vbs: rawVbs, reversed: true
            )
        }
        return OperatingPointResult(
            isd: isd, gm: gm, gds: gds, gmbs: gmbs,
            vsg: vsg, vsd: vsd, vbs: vbs, reversed: false
        )
    }

    /// Stamp the linearised PMOS model around the operating point.
    ///
    /// Current flows from source to drain:
    ///   `I_stamp = Isd0 + gm * (Vsg - Vsg0) + gds * (Vsd - Vsd0) + gmbs * (Vbs - Vbs0)`
    ///   `       = gm * Vsg + gds * Vsd + gmbs * Vbs + (Isd0 - gm*Vsg0 - gds*Vsd0 - gmbs*Vbs0)`
    private func stampLinearized(into stamper: inout MatrixStamper, op: OperatingPointResult) {
        // When Vsd < 0, source and drain are physically swapped
        let effectiveDrain = op.reversed ? source : drain
        let effectiveSource = op.reversed ? drain : source
        let dIdx = stamper.nodeIndex(effectiveDrain)
        let gIdx = stamper.nodeIndex(gate)
        let sIdx = stamper.nodeIndex(effectiveSource)
        let bIdx = stamper.nodeIndex(bulk)

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

        // Body transconductance stamps: gmbs from Vbs
        // Isd += gmbs * Vbs = gmbs * (Vb - Vs)
        // For PMOS, increasing Vbs (bulk more positive) reduces |Vtp|, increases Isd.
        // Current contribution: from source, controlled by (Vb - Vs)
        if op.gmbs != 0 {
            if let sIdx, let bIdx {
                stamper.stampMatrix(sIdx, bIdx, -op.gmbs)
            }
            if let sIdx {
                stamper.stampMatrix(sIdx, sIdx, op.gmbs)
            }
            if let dIdx, let bIdx {
                stamper.stampMatrix(dIdx, bIdx, op.gmbs)
            }
            if let dIdx, let sIdx {
                stamper.stampMatrix(dIdx, sIdx, -op.gmbs)
            }
        }

        // Equivalent current source: Ieq = Isd - gm*Vsg - gds*Vsd - gmbs*Vbs
        // Positive Ieq means current from source to drain
        let ieq = op.isd - op.gm * op.vsg - op.gds * op.vsd - op.gmbs * op.vbs

        // Current leaves source (negative contribution) and enters drain (positive)
        if let sIdx {
            stamper.stampRHS(sIdx, -ieq)
        }
        if let dIdx {
            stamper.stampRHS(dIdx, ieq)
        }
    }
}

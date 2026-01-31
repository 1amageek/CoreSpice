import Foundation
import CoreSpiceIR

/// An NMOS Level 1 MOSFET bound to circuit nodes.
///
/// Implements the Shichman-Hodges model with three operating regions:
/// - **Cutoff**: `Vgs < Vth` -- no current flows.
/// - **Linear (triode)**: `Vgs >= Vth` and `Vds < Vgs - Vth`.
/// - **Saturation**: `Vgs >= Vth` and `Vds >= Vgs - Vth`.
///
/// Body effect modulates the threshold voltage via the bulk-source voltage:
///   `Vth = Vto + gamma * (sqrt(2*phi - Vbs) - sqrt(2*phi))`
///
/// The device is linearised around the current operating point for
/// Newton-Raphson iteration.
public struct BoundNMOSL1: BoundDevice, Sendable {

    public let instance: Instance
    private let drain: Node
    private let gate: Node
    private let source: Node
    private let bulk: Node
    private let parameters: MOSFETModelParameters

    /// Pre-resolved matrix indices for fast voltage lookups.
    private let drainIdx: Int?
    private let gateIdx: Int?
    private let sourceIdx: Int?
    private let bulkIdx: Int?

    /// Convergence tolerance for terminal voltages (V).
    private static let voltageTolerance: Double = 1e-6

    init(
        instance: Instance,
        drain: Node,
        gate: Node,
        source: Node,
        bulk: Node,
        parameters: MOSFETModelParameters,
        drainIdx: Int?,
        gateIdx: Int?,
        sourceIdx: Int?,
        bulkIdx: Int?
    ) {
        self.instance = instance
        self.drain = drain
        self.gate = gate
        self.source = source
        self.bulk = bulk
        self.parameters = parameters
        self.drainIdx = drainIdx
        self.gateIdx = gateIdx
        self.sourceIdx = sourceIdx
        self.bulkIdx = bulkIdx
    }

    /// Retrieve a node voltage by pre-resolved index, returning 0 for ground nodes.
    private func nodeVoltage(_ idx: Int?, _ state: SolutionState) -> Double {
        if let idx { return state.value(at: idx) } else { return 0 }
    }

    // MARK: - BoundDevice

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        let op = operatingPoint(state: state)
        stampLinearized(into: &stamper, op: op)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        // Small-signal model: stamp gm, gds, and gmbs
        let op = operatingPoint(state: state)
        let effectiveDrain = op.reversed ? source : drain
        let effectiveSource = op.reversed ? drain : source
        let dIdx = stamper.nodeIndex(effectiveDrain)
        let gIdx = stamper.nodeIndex(gate)
        let sIdx = stamper.nodeIndex(effectiveSource)
        let bIdx = stamper.nodeIndex(bulk)

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

        // gmbs: body transconductance (bulk-source voltage modulates threshold)
        // Id += gmbs * Vbs => stamp gmbs from bulk to drain-source
        if op.gmbs != 0 {
            if let dIdx, let bIdx {
                stamper.stampMatrix(dIdx, bIdx, op.gmbs, 0.0)
            }
            if let dIdx, let sIdx {
                stamper.stampMatrix(dIdx, sIdx, -op.gmbs, 0.0)
            }
            if let sIdx, let bIdx {
                stamper.stampMatrix(sIdx, bIdx, -op.gmbs, 0.0)
            }
            if let sIdx {
                stamper.stampMatrix(sIdx, sIdx, op.gmbs, 0.0)
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
        let vgsNew = nodeVoltage(gateIdx, state) - nodeVoltage(sourceIdx, state)
        let vgsOld = nodeVoltage(gateIdx, previousState) - nodeVoltage(sourceIdx, previousState)
        let vdsNew = nodeVoltage(drainIdx, state) - nodeVoltage(sourceIdx, state)
        let vdsOld = nodeVoltage(drainIdx, previousState) - nodeVoltage(sourceIdx, previousState)
        let vbsNew = nodeVoltage(bulkIdx, state) - nodeVoltage(sourceIdx, state)
        let vbsOld = nodeVoltage(bulkIdx, previousState) - nodeVoltage(sourceIdx, previousState)

        let deltaVgs = abs(vgsNew - vgsOld)
        let deltaVds = abs(vdsNew - vdsOld)
        let deltaVbs = abs(vbsNew - vbsOld)
        let maxDelta = max(deltaVgs, max(deltaVds, deltaVbs))

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
        let gmbs: Double  // body transconductance dIds/dVbs
        let vgs: Double
        let vds: Double
        let vbs: Double
        let reversed: Bool // true when source and drain are swapped (Vds < 0)
    }

    private func operatingPoint(state: SolutionState) -> OperatingPointResult {
        let vGate = nodeVoltage(gateIdx, state)
        let vDrain = nodeVoltage(drainIdx, state)
        let vSource = nodeVoltage(sourceIdx, state)
        let vBulk = nodeVoltage(bulkIdx, state)

        let rawVgs = vGate - vSource
        let rawVds = vDrain - vSource
        let rawVbs = vBulk - vSource
        let beta = parameters.beta
        let lambda = parameters.lambda

        // MOSFET is symmetric: when Vds < 0, swap source and drain
        let reversed = rawVds < 0
        let vgs: Double
        let vds: Double
        let vbs: Double
        if reversed {
            vds = -rawVds
            vgs = vGate - vDrain
            vbs = vBulk - vDrain
        } else {
            vds = rawVds
            vgs = rawVgs
            vbs = rawVbs
        }

        // Body effect: threshold voltage modulation
        let twoPhi = 2.0 * parameters.phi
        let sqrtTwoPhi = sqrt(abs(twoPhi))
        let twoPhiMinusVbs = max(twoPhi - vbs, 0.01)
        let vth = parameters.vto + parameters.gamma * (sqrt(twoPhiMinusVbs) - sqrtTwoPhi)

        if vgs < vth {
            // Cutoff
            return OperatingPointResult(
                ids: 0, gm: 0, gds: 0, gmbs: 0,
                vgs: rawVgs, vds: rawVds, vbs: rawVbs, reversed: reversed
            )
        }

        let vgst = vgs - vth

        let ids: Double
        let gm: Double
        let gds: Double

        if vds < vgst {
            // Linear region: Ids = beta * (Vgst * Vds - 0.5 * Vds^2) * (1 + lambda * Vds)
            ids = beta * (vgst * vds - 0.5 * vds * vds) * (1.0 + lambda * vds)
            gm = beta * vds * (1.0 + lambda * vds)
            gds = beta * (vgst - vds) * (1.0 + lambda * vds)
                    + beta * (vgst * vds - 0.5 * vds * vds) * lambda
        } else {
            // Saturation region: Ids = 0.5 * beta * Vgst^2 * (1 + lambda * Vds)
            ids = 0.5 * beta * vgst * vgst * (1.0 + lambda * vds)
            gm = beta * vgst * (1.0 + lambda * vds)
            gds = 0.5 * beta * vgst * vgst * lambda
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
                ids: -ids, gm: gm, gds: gds, gmbs: gmbs,
                vgs: rawVgs, vds: rawVds, vbs: rawVbs, reversed: true
            )
        }
        return OperatingPointResult(
            ids: ids, gm: gm, gds: gds, gmbs: gmbs,
            vgs: vgs, vds: vds, vbs: vbs, reversed: false
        )
    }

    /// Stamp the linearised model around the operating point.
    ///
    /// The Newton-Raphson linearisation gives:
    ///   `I_stamp = Ids0 + gm * (Vgs - Vgs0) + gds * (Vds - Vds0) + gmbs * (Vbs - Vbs0)`
    ///   `       = gm * Vgs + gds * Vds + gmbs * Vbs + (Ids0 - gm*Vgs0 - gds*Vds0 - gmbs*Vbs0)`
    ///
    /// The last term is the equivalent current source (RHS).
    private func stampLinearized(into stamper: inout MatrixStamper, op: OperatingPointResult) {
        // When Vds < 0, source and drain are physically swapped
        let effectiveDrain = op.reversed ? source : drain
        let effectiveSource = op.reversed ? drain : source
        let dIdx = stamper.nodeIndex(effectiveDrain)
        let gIdx = stamper.nodeIndex(gate)
        let sIdx = stamper.nodeIndex(effectiveSource)
        let bIdx = stamper.nodeIndex(bulk)

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

        // Body transconductance stamps: gmbs contribution from bulk-source voltage
        if op.gmbs != 0 {
            if let dIdx, let bIdx {
                stamper.stampMatrix(dIdx, bIdx, op.gmbs)
            }
            if let dIdx, let sIdx {
                stamper.stampMatrix(dIdx, sIdx, -op.gmbs)
            }
            if let sIdx, let bIdx {
                stamper.stampMatrix(sIdx, bIdx, -op.gmbs)
            }
            if let sIdx {
                stamper.stampMatrix(sIdx, sIdx, op.gmbs)
            }
        }

        // Equivalent current source: Ieq = Ids - gm*Vgs - gds*Vds - gmbs*Vbs
        let ieq = op.ids - op.gm * op.vgs - op.gds * op.vds - op.gmbs * op.vbs

        if let dIdx {
            stamper.stampRHS(dIdx, ieq)
        }
        if let sIdx {
            stamper.stampRHS(sIdx, -ieq)
        }
    }
}

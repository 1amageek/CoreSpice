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
public struct BoundPMOSL1: BoundDevice, VoltageLimitingDevice, Sendable {

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

    /// Minimum output conductance to prevent singular matrix in cutoff.
    private static let minGds: Double = 1e-12

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

        // Meyer gate capacitances + junction capacitances as jωC susceptances
        let caps = meyerCapacitances(state: state)
        stampACCapacitance(into: &stamper, node1: gIdx, node2: sIdx, cap: caps.cgs, omega: omega)
        stampACCapacitance(into: &stamper, node1: gIdx, node2: dIdx, cap: caps.cgd, omega: omega)
        stampACCapacitance(into: &stamper, node1: gIdx, node2: bIdx, cap: caps.cgb, omega: omega)
        stampACCapacitance(into: &stamper, node1: bIdx, node2: dIdx, cap: caps.cbd, omega: omega)
        stampACCapacitance(into: &stamper, node1: bIdx, node2: sIdx, cap: caps.cbs, omega: omega)
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        // DC (quasi-static I-V) part
        stampDC(into: &stamper, state: state)

        // Meyer capacitance companion models
        let caps = meyerCapacitances(state: state)

        let op = operatingPoint(state: state)
        let effectiveDrain = op.reversed ? source : drain
        let effectiveSource = op.reversed ? drain : source
        let edIdx = stamper.nodeIndex(effectiveDrain)
        let esIdx = stamper.nodeIndex(effectiveSource)
        let gIdx2 = stamper.nodeIndex(gate)
        let bIdx2 = stamper.nodeIndex(bulk)

        stampTransientCapacitance(into: &stamper, node1: gIdx2, node2: esIdx, cap: caps.cgs, state: state, integration: integration)
        stampTransientCapacitance(into: &stamper, node1: gIdx2, node2: edIdx, cap: caps.cgd, state: state, integration: integration)
        stampTransientCapacitance(into: &stamper, node1: gIdx2, node2: bIdx2, cap: caps.cgb, state: state, integration: integration)
        stampTransientCapacitance(into: &stamper, node1: bIdx2, node2: edIdx, cap: caps.cbd, state: state, integration: integration)
        stampTransientCapacitance(into: &stamper, node1: bIdx2, node2: esIdx, cap: caps.cbs, state: state, integration: integration)
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        let vsgNew = nodeVoltage(sourceIdx, state) - nodeVoltage(gateIdx, state)
        let vsgOld = nodeVoltage(sourceIdx, previousState) - nodeVoltage(gateIdx, previousState)
        let vsdNew = nodeVoltage(sourceIdx, state) - nodeVoltage(drainIdx, state)
        let vsdOld = nodeVoltage(sourceIdx, previousState) - nodeVoltage(drainIdx, previousState)
        let vbsNew = nodeVoltage(bulkIdx, state) - nodeVoltage(sourceIdx, state)
        let vbsOld = nodeVoltage(bulkIdx, previousState) - nodeVoltage(sourceIdx, previousState)

        let deltaVsg = abs(vsgNew - vsgOld)
        let deltaVsd = abs(vsdNew - vsdOld)
        let deltaVbs = abs(vbsNew - vbsOld)
        let maxDelta = max(deltaVsg, max(deltaVsd, deltaVbs))

        if maxDelta < Self.voltageTolerance {
            return .converged
        }
        return .notConverged(maxDelta: maxDelta, deviceName: instance.name)
    }

    // MARK: - VoltageLimitingDevice

    /// Maximum Vsg change per NR iteration (V).
    private static let maxVgsStep: Double = 0.5
    /// Maximum Vsd change per NR iteration (V).
    private static let maxVdsStep: Double = 1.0

    public func limitVoltages(solution: inout [Double], previousSolution: [Double]) {
        let vgNew = gateIdx.map { solution[$0] } ?? 0.0
        let vdNew = drainIdx.map { solution[$0] } ?? 0.0
        let vsNew = sourceIdx.map { solution[$0] } ?? 0.0

        let vgOld = gateIdx.map { previousSolution[$0] } ?? 0.0
        let vdOld = drainIdx.map { previousSolution[$0] } ?? 0.0
        let vsOld = sourceIdx.map { previousSolution[$0] } ?? 0.0

        // PMOS uses Vsg and Vsd (source-referenced)
        let vsgNew = vsNew - vgNew
        let vsgOld = vsOld - vgOld
        let vsdNew = vsNew - vdNew
        let vsdOld = vsOld - vdOld

        var deltaVsg = vsgNew - vsgOld
        var deltaVsd = vsdNew - vsdOld

        // Clamp Vsg change
        if abs(deltaVsg) > Self.maxVgsStep {
            deltaVsg = deltaVsg > 0 ? Self.maxVgsStep : -Self.maxVgsStep
        }
        // Clamp Vsd change
        if abs(deltaVsd) > Self.maxVdsStep {
            deltaVsd = deltaVsd > 0 ? Self.maxVdsStep : -Self.maxVdsStep
        }

        let vsgLimited = vsgOld + deltaVsg
        let vsdLimited = vsdOld + deltaVsd

        let vsgCorrected = vsgLimited - vsgNew
        let vsdCorrected = vsdLimited - vsdNew

        if vsgCorrected != 0 || vsdCorrected != 0 {
            // For PMOS: Vsg = Vs - Vg, so to increase Vsg we decrease Vg
            if let gIdx = gateIdx {
                solution[gIdx] -= vsgCorrected
            }
            // Vsd = Vs - Vd, so to increase Vsd we decrease Vd
            if let dIdx = drainIdx {
                solution[dIdx] -= vsdCorrected
            }
        }
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
        let vGate = nodeVoltage(gateIdx, state)
        let vDrain = nodeVoltage(drainIdx, state)
        let vSource = nodeVoltage(sourceIdx, state)
        let vBulk = nodeVoltage(bulkIdx, state)

        let rawVsg = vSource - vGate
        let rawVsd = vSource - vDrain
        let rawVbs = vBulk - vSource

        let beta = parameters.beta
        let lambda = parameters.lambda

        // PMOS is symmetric: when Vsd < 0, swap source and drain
        let reversed = rawVsd < 0
        let vsg: Double
        let vsd: Double
        let vbs: Double
        if reversed {
            vsd = -rawVsd
            vsg = vDrain - vGate
            vbs = vBulk - vDrain
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
            // Cutoff — minGds prevents singular matrix when all terminals float
            return OperatingPointResult(
                isd: 0, gm: 0, gds: Self.minGds, gmbs: 0,
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
            // When reversed, stamps use effective (swapped) terminals.
            // Store effective voltages and positive current so ieq formula is consistent.
            return OperatingPointResult(
                isd: isd, gm: gm, gds: gds, gmbs: gmbs,
                vsg: vsg, vsd: vsd, vbs: vbs, reversed: true
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

        // Equivalent current source: Ieq = Isd - (matrix conductance contribution at operating point)
        // The gmbs stamps encode -gmbs (since dIsd/dVbs < 0 for PMOS, gmbs is stored as positive magnitude).
        // Matrix body-effect contribution at S row: -gmbs*Vbs, so ieq must use +gmbs*Vbs to compensate.
        let ieq = op.isd - op.gm * op.vsg - op.gds * op.vsd + op.gmbs * op.vbs

        // Current leaves source (negative contribution) and enters drain (positive)
        if let sIdx {
            stamper.stampRHS(sIdx, -ieq)
        }
        if let dIdx {
            stamper.stampRHS(dIdx, ieq)
        }
    }

    // MARK: - Meyer Capacitance Model

    private struct MeyerCapacitances {
        let cgs: Double
        let cgd: Double
        let cgb: Double
        let cbd: Double
        let cbs: Double
    }

    private func meyerCapacitances(state: SolutionState) -> MeyerCapacitances {
        let op = operatingPoint(state: state)
        let cox = parameters.cox
        let w = parameters.w
        let l = parameters.l

        // Overlap capacitances (always present)
        let cgsOverlap = parameters.cgso * w
        let cgdOverlap = parameters.cgdo * w
        let cgbOverlap = parameters.cgbo * l

        // PMOS: use Vsg and Vsd
        let vsg = op.reversed ? (nodeVoltage(drainIdx, state) - nodeVoltage(gateIdx, state)) : (nodeVoltage(sourceIdx, state) - nodeVoltage(gateIdx, state))
        let vsd = abs(nodeVoltage(sourceIdx, state) - nodeVoltage(drainIdx, state))

        let twoPhi = 2.0 * parameters.phi
        let sqrtTwoPhi = sqrt(abs(twoPhi))
        let vbs = nodeVoltage(bulkIdx, state) - nodeVoltage(sourceIdx, state)
        let twoPhiMinusVbs = max(twoPhi - vbs, 0.01)
        // For PMOS: Vtp < 0, so |Vtp| is the conduction threshold for Vsg
        let vtp = parameters.vto + parameters.gamma * (sqrt(twoPhiMinusVbs) - sqrtTwoPhi)
        let vtpAbs = -vtp

        let coxWL = cox * w * l
        let cgs: Double
        let cgd: Double
        let cgb: Double

        let vsgOverdrive = vsg - vtpAbs
        if vsgOverdrive <= 0 {
            // Cutoff: all channel capacitance goes to gate-bulk
            cgs = cgsOverlap
            cgd = cgdOverlap
            cgb = coxWL + cgbOverlap
        } else if vsd < vsgOverdrive {
            // Linear region
            let ratio1 = (vsgOverdrive - vsd) / (2.0 * vsgOverdrive - vsd)
            let ratio2 = vsgOverdrive / (2.0 * vsgOverdrive - vsd)
            cgs = coxWL * 2.0 / 3.0 * (1.0 - ratio1 * ratio1) + cgsOverlap
            cgd = coxWL * 2.0 / 3.0 * (1.0 - ratio2 * ratio2) + cgdOverlap
            cgb = cgbOverlap
        } else {
            // Saturation
            cgs = 2.0 / 3.0 * coxWL + cgsOverlap
            cgd = cgdOverlap
            cgb = cgbOverlap
        }

        // Junction capacitances (PMOS: bulk is typically at VDD)
        let vbd = nodeVoltage(bulkIdx, state) - (op.reversed ? nodeVoltage(sourceIdx, state) : nodeVoltage(drainIdx, state))
        let vbsJunc = nodeVoltage(bulkIdx, state) - (op.reversed ? nodeVoltage(drainIdx, state) : nodeVoltage(sourceIdx, state))

        let cbd = junctionCapacitance(vj: vbd, area: parameters.ad, perimeter: parameters.pd)
        let cbs = junctionCapacitance(vj: vbsJunc, area: parameters.asrc, perimeter: parameters.ps)

        return MeyerCapacitances(cgs: cgs, cgd: cgd, cgb: cgb, cbd: cbd, cbs: cbs)
    }

    private func junctionCapacitance(vj: Double, area: Double, perimeter: Double) -> Double {
        let pb = parameters.pb
        guard pb > 0 else { return 0 }

        let cjBottom: Double
        if parameters.cj > 0 && area > 0 {
            if vj < 0.5 * pb {
                cjBottom = parameters.cj * area / pow(1.0 - vj / pb, parameters.mj)
            } else {
                let cjHalf = parameters.cj * area / pow(0.5, parameters.mj)
                let slope = cjHalf * parameters.mj / (pb * 0.5)
                cjBottom = cjHalf + slope * (vj - 0.5 * pb)
            }
        } else {
            cjBottom = 0
        }

        let cjSidewall: Double
        if parameters.cjsw > 0 && perimeter > 0 {
            if vj < 0.5 * pb {
                cjSidewall = parameters.cjsw * perimeter / pow(1.0 - vj / pb, parameters.mjsw)
            } else {
                let cjswHalf = parameters.cjsw * perimeter / pow(0.5, parameters.mjsw)
                let slope = cjswHalf * parameters.mjsw / (pb * 0.5)
                cjSidewall = cjswHalf + slope * (vj - 0.5 * pb)
            }
        } else {
            cjSidewall = 0
        }

        return cjBottom + cjSidewall
    }

    // MARK: - Capacitance Stamping Helpers

    private func stampACCapacitance(
        into stamper: inout ComplexMatrixStamper,
        node1: Int?, node2: Int?,
        cap: Double, omega: Double
    ) {
        guard cap > 0 else { return }
        let susceptance = omega * cap
        if let n1 = node1 {
            stamper.stampMatrix(n1, n1, 0.0, susceptance)
        }
        if let n2 = node2 {
            stamper.stampMatrix(n2, n2, 0.0, susceptance)
        }
        if let n1 = node1, let n2 = node2 {
            stamper.stampMatrix(n1, n2, 0.0, -susceptance)
            stamper.stampMatrix(n2, n1, 0.0, -susceptance)
        }
    }

    private func stampTransientCapacitance(
        into stamper: inout MatrixStamper,
        node1: Int?, node2: Int?,
        cap: Double,
        state: SolutionState,
        integration: IntegrationState
    ) {
        guard cap > 0 else { return }
        let geq = integration.coefficient * cap
        let v1 = node1.map { state.previousValue(at: $0) } ?? 0.0
        let v2 = node2.map { state.previousValue(at: $0) } ?? 0.0
        let vPrev = v1 - v2

        let ieq: Double
        switch integration.method {
        case .backwardEuler:
            ieq = geq * vPrev
        case .trapezoidal:
            let v1pp = node1.map { state.twoPreviousValue(at: $0) } ?? 0.0
            let v2pp = node2.map { state.twoPreviousValue(at: $0) } ?? 0.0
            let vPrevPrev = v1pp - v2pp
            let dtPrev = integration.previousTimeStep ?? integration.timeStep
            let iCapPrev = cap * (vPrev - vPrevPrev) / dtPrev
            ieq = geq * vPrev + iCapPrev
        }

        if let n1 = node1 {
            stamper.stampMatrix(n1, n1, geq)
        }
        if let n2 = node2 {
            stamper.stampMatrix(n2, n2, geq)
        }
        if let n1 = node1, let n2 = node2 {
            stamper.stampMatrix(n1, n2, -geq)
            stamper.stampMatrix(n2, n1, -geq)
        }

        if let n1 = node1 {
            stamper.stampRHS(n1, ieq)
        }
        if let n2 = node2 {
            stamper.stampRHS(n2, -ieq)
        }
    }
}

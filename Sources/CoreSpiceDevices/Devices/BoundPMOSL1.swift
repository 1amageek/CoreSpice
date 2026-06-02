import Foundation
import CoreSpiceIR

/// A PMOS Level 1 MOSFET bound to circuit nodes.
///
/// Implements the Shichman-Hodges model with reversed polarities
/// compared to the NMOS device. The PMOS conducts when `Vsg > |Vtp|`
/// (equivalently `Vgs < Vtp` where Vtp is negative).
///
/// Body effect modulates the threshold voltage via the bulk-source voltage:
///   `Vth = Vto + gamma * (sqrt(phi - Vbs) - sqrt(phi))`
///
/// Operating regions (using source-referenced voltages):
/// - **Cutoff**: `Vsg < |Vtp|` -- no current flows.
/// - **Linear**: `Vsg >= |Vtp|` and `Vsd < Vsg - |Vtp|`.
/// - **Saturation**: `Vsg >= |Vtp|` and `Vsd >= Vsg - |Vtp|`.
///
/// Current flows from source to drain (conventional direction).
public struct BoundPMOSL1: BoundDevice, VoltageLimitingDevice, TransientStateCommittingDevice, Sendable {

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

    /// Pre-resolved CSR value indices for O(1) stamping.
    /// Only used when device is not in reversed mode.
    private let csrIndices: MOSFETCSRIndices
    private let capacitanceStore: TransientCapacitanceStore

    /// Convergence tolerance for terminal voltages (V).
    private static let voltageTolerance: Double = 1e-6

    /// Minimum output conductance to prevent singular matrix in cutoff.
    private static let minGds: Double = 1e-12

    /// Smoothing parameter for the cutoff-to-on transition (≈ kT/q at room temperature).
    private static let smoothDelta: Double = 0.025

    /// Smooth approximation of max(x, 0) for continuous derivatives.
    private static func smoothClamp(_ x: Double) -> Double {
        0.5 * (x + sqrt(x * x + smoothDelta * smoothDelta))
    }

    /// Derivative of smoothClamp: d/dx smoothClamp(x).
    private static func smoothClampDeriv(_ x: Double) -> Double {
        0.5 * (1.0 + x / sqrt(x * x + smoothDelta * smoothDelta))
    }

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
        bulkIdx: Int?,
        csrIndices: MOSFETCSRIndices = MOSFETCSRIndices()
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
        self.csrIndices = csrIndices
        self.capacitanceStore = TransientCapacitanceStore()
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

        capacitanceStore.stamp(key: "cgs", into: &stamper, node1: gIdx2, node2: esIdx, capacitance: caps.cgs, state: state, integration: integration)
        capacitanceStore.stamp(key: "cgd", into: &stamper, node1: gIdx2, node2: edIdx, capacitance: caps.cgd, state: state, integration: integration)
        capacitanceStore.stamp(key: "cgb", into: &stamper, node1: gIdx2, node2: bIdx2, capacitance: caps.cgb, state: state, integration: integration)
        capacitanceStore.stamp(key: "cbd", into: &stamper, node1: bIdx2, node2: edIdx, capacitance: caps.cbd, state: state, integration: integration)
        capacitanceStore.stamp(key: "cbs", into: &stamper, node1: bIdx2, node2: esIdx, capacitance: caps.cbs, state: state, integration: integration)
    }

    public func commitTransientStep(state: SolutionState, integration: IntegrationState) {
        let caps = meyerCapacitances(state: state)
        let op = operatingPoint(state: state)
        let edIdx = op.reversed ? sourceIdx : drainIdx
        let esIdx = op.reversed ? drainIdx : sourceIdx
        capacitanceStore.commit(key: "cgs", node1: gateIdx, node2: esIdx, capacitance: caps.cgs, state: state, integration: integration)
        capacitanceStore.commit(key: "cgd", node1: gateIdx, node2: edIdx, capacitance: caps.cgd, state: state, integration: integration)
        capacitanceStore.commit(key: "cgb", node1: gateIdx, node2: bulkIdx, capacitance: caps.cgb, state: state, integration: integration)
        capacitanceStore.commit(key: "cbd", node1: bulkIdx, node2: edIdx, capacitance: caps.cbd, state: state, integration: integration)
        capacitanceStore.commit(key: "cbs", node1: bulkIdx, node2: esIdx, capacitance: caps.cbs, state: state, integration: integration)
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
        // Vtp = VTO + gamma * (sqrt(phi - Vbs) - sqrt(phi))
        // For PMOS, VTO < 0, and |Vtp| = -Vtp
        let surfacePotential = parameters.phi
        let sqrtPhi = sqrt(abs(surfacePotential))
        let phiMinusVbs = max(surfacePotential - vbs, 0.01)
        let vtp = parameters.vto + parameters.gamma * (sqrt(phiMinusVbs) - sqrtPhi)
        // |Vtp| for the conduction check
        let vtpAbs = -vtp

        // Smooth overdrive: continuous transition through cutoff (no hard if/else)
        let rawVsgOverdrive = vsg - vtpAbs
        let vsgOverdrive = Self.smoothClamp(rawVsgOverdrive)
        let dvsgOverdrive = Self.smoothClampDeriv(rawVsgOverdrive) // d(vsgOverdrive)/d(vsg)

        let isd: Double
        let gm: Double
        let gds: Double

        if vsd < vsgOverdrive {
            // Linear region: Isd = beta * (Vov * Vsd - 0.5 * Vsd^2) * (1 + lambda * Vsd)
            let clm = 1.0 + lambda * vsd
            isd = beta * (vsgOverdrive * vsd - 0.5 * vsd * vsd) * clm
            // gm = dIsd/dVsg = dIsd/dVsgOverdrive * dVsgOverdrive/dVsg
            gm = beta * vsd * clm * dvsgOverdrive
            gds = beta * (vsgOverdrive - vsd) * clm
                    + beta * (vsgOverdrive * vsd - 0.5 * vsd * vsd) * lambda
        } else {
            // Saturation region: Isd = 0.5 * beta * Vov^2 * (1 + lambda * Vsd)
            let clm = 1.0 + lambda * vsd
            isd = 0.5 * beta * vsgOverdrive * vsgOverdrive * clm
            // gm = dIsd/dVsg = beta * Vov * clm * dVsgOverdrive/dVsg
            gm = beta * vsgOverdrive * clm * dvsgOverdrive
            gds = 0.5 * beta * vsgOverdrive * vsgOverdrive * lambda
        }

        // Ensure minimum gds to prevent singular matrix
        let effectiveGds = max(gds, Self.minGds)

        // Body transconductance: gmbs = gm * gamma / (2 * sqrt(phi - Vbs))
        let gmbs: Double
        if parameters.gamma > 0 {
            gmbs = gm * parameters.gamma / (2.0 * sqrt(phiMinusVbs))
        } else {
            gmbs = 0
        }

        if reversed {
            // When reversed, stamps use effective (swapped) terminals.
            // Store effective voltages and positive current so ieq formula is consistent.
            return OperatingPointResult(
                isd: isd, gm: gm, gds: effectiveGds, gmbs: gmbs,
                vsg: vsg, vsd: vsd, vbs: vbs, reversed: true
            )
        }
        return OperatingPointResult(
            isd: isd, gm: gm, gds: effectiveGds, gmbs: gmbs,
            vsg: vsg, vsd: vsd, vbs: vbs, reversed: false
        )
    }

    /// Stamp the linearised PMOS model around the operating point.
    ///
    /// Current flows from source to drain:
    ///   `I_stamp = Isd0 + gm * (Vsg - Vsg0) + gds * (Vsd - Vsd0) + gmbs * (Vbs - Vbs0)`
    ///   `       = gm * Vsg + gds * Vsd + gmbs * Vbs + (Isd0 - gm*Vsg0 - gds*Vsd0 - gmbs*Vbs0)`
    private func stampLinearized(into stamper: inout MatrixStamper, op: OperatingPointResult) {
        // Fast path: use pre-resolved CSR indices for O(1) stamping (non-reversed case only)
        if !op.reversed, let sv = stamper.stampValue, csrIndices.ss != nil || csrIndices.dd != nil {
            // PMOS Jacobian: current flows from S to D
            // J[S,S] = gds + gm + gmbs, J[D,D] = gds
            // J[S,D] = -gds, J[D,S] = -gds - gm - gmbs
            // J[S,G] = -gm, J[D,G] = gm
            // J[S,B] = -gmbs, J[D,B] = gmbs
            if let idx = csrIndices.ss { sv(idx, op.gds + op.gm + op.gmbs) }
            if let idx = csrIndices.dd { sv(idx, op.gds) }
            if let idx = csrIndices.sd { sv(idx, -op.gds) }
            if let idx = csrIndices.ds { sv(idx, -op.gds - op.gm - op.gmbs) }
            if let idx = csrIndices.sg { sv(idx, -op.gm) }
            if let idx = csrIndices.dg { sv(idx, op.gm) }
            if let idx = csrIndices.sb { sv(idx, -op.gmbs) }
            if let idx = csrIndices.db { sv(idx, op.gmbs) }
        } else {
            // Fallback to dictionary-based stamping (for reversed case or no CSR indices)
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
        }

        // Equivalent current source: Ieq = Isd - (matrix conductance contribution at operating point)
        // The gmbs stamps encode -gmbs (since dIsd/dVbs < 0 for PMOS, gmbs is stored as positive magnitude).
        // Matrix body-effect contribution at S row: -gmbs*Vbs, so ieq must use +gmbs*Vbs to compensate.
        let ieq = op.isd - op.gm * op.vsg - op.gds * op.vsd + op.gmbs * op.vbs

        // Use pre-resolved indices for RHS stamping
        let effectiveSourceIdx = op.reversed ? drainIdx : sourceIdx
        let effectiveDrainIdx = op.reversed ? sourceIdx : drainIdx

        // Current leaves source (negative contribution) and enters drain (positive)
        if let sIdx = effectiveSourceIdx {
            stamper.stampRHS(sIdx, -ieq)
        }
        if let dIdx = effectiveDrainIdx {
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

        let surfacePotential = parameters.phi
        let sqrtPhi = sqrt(abs(surfacePotential))
        let vbs = nodeVoltage(bulkIdx, state) - nodeVoltage(sourceIdx, state)
        let phiMinusVbs = max(surfacePotential - vbs, 0.01)
        // For PMOS: Vtp < 0, so |Vtp| is the conduction threshold for Vsg
        let vtp = parameters.vto + parameters.gamma * (sqrt(phiMinusVbs) - sqrtPhi)
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

}

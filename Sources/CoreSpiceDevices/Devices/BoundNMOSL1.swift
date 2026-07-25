import Foundation
import CoreSpiceIR

/// Pre-resolved CSR value indices for MOSFET O(1) stamping.
///
/// Contains indices for the 4-terminal device (D, G, S, B).
/// Only used when the device is not in reversed mode (Vds >= 0).
public struct MOSFETCSRIndices: Sendable {
    // Diagonal entries
    let dd: Int?, gg: Int?, ss: Int?, bb: Int?
    // Off-diagonal entries
    let dg: Int?, ds: Int?, db: Int?
    let gd: Int?, gs: Int?, gb: Int?
    let sd: Int?, sg: Int?, sb: Int?
    let bd: Int?, bg: Int?, bs: Int?

    public init(
        dd: Int? = nil, gg: Int? = nil, ss: Int? = nil, bb: Int? = nil,
        dg: Int? = nil, ds: Int? = nil, db: Int? = nil,
        gd: Int? = nil, gs: Int? = nil, gb: Int? = nil,
        sd: Int? = nil, sg: Int? = nil, sb: Int? = nil,
        bd: Int? = nil, bg: Int? = nil, bs: Int? = nil
    ) {
        self.dd = dd; self.gg = gg; self.ss = ss; self.bb = bb
        self.dg = dg; self.ds = ds; self.db = db
        self.gd = gd; self.gs = gs; self.gb = gb
        self.sd = sd; self.sg = sg; self.sb = sb
        self.bd = bd; self.bg = bg; self.bs = bs
    }
}

/// An NMOS Level 1 MOSFET bound to circuit nodes.
///
/// Implements the Shichman-Hodges model with three operating regions:
/// - **Cutoff**: `Vgs < Vth` -- no current flows.
/// - **Linear (triode)**: `Vgs >= Vth` and `Vds < Vgs - Vth`.
/// - **Saturation**: `Vgs >= Vth` and `Vds >= Vgs - Vth`.
///
/// Body effect modulates the threshold voltage via the bulk-source voltage:
///   `Vth = Vto + gamma * (sqrt(phi - Vbs) - sqrt(phi))`
///
/// The device is linearised around the current operating point for
/// Newton-Raphson iteration.
public struct BoundNMOSL1: BoundDevice, VoltageLimitingDevice, TransientStateCommittingDevice, NoisyDevice, Sendable {

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

        // gmbs: body transconductance
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
        let cgsKey = op.reversed ? "cgd" : "cgs"
        let cgdKey = op.reversed ? "cgs" : "cgd"
        let cbdKey = op.reversed ? "cbs" : "cbd"
        let cbsKey = op.reversed ? "cbd" : "cbs"

        capacitanceStore.stamp(key: cgsKey, into: &stamper, node1: gIdx2, node2: esIdx, capacitance: caps.cgs, state: state, integration: integration)
        capacitanceStore.stamp(key: cgdKey, into: &stamper, node1: gIdx2, node2: edIdx, capacitance: caps.cgd, state: state, integration: integration)
        capacitanceStore.stamp(key: "cgb", into: &stamper, node1: gIdx2, node2: bIdx2, capacitance: caps.cgb, state: state, integration: integration)
        capacitanceStore.stamp(key: cbdKey, into: &stamper, node1: bIdx2, node2: edIdx, capacitance: caps.cbd, state: state, integration: integration)
        capacitanceStore.stamp(key: cbsKey, into: &stamper, node1: bIdx2, node2: esIdx, capacitance: caps.cbs, state: state, integration: integration)
    }

    public func commitTransientStep(state: SolutionState, integration: IntegrationState) {
        let caps = meyerCapacitances(state: state)
        let op = operatingPoint(state: state)
        let edIdx = op.reversed ? sourceIdx : drainIdx
        let esIdx = op.reversed ? drainIdx : sourceIdx
        let cgsKey = op.reversed ? "cgd" : "cgs"
        let cgdKey = op.reversed ? "cgs" : "cgd"
        let cbdKey = op.reversed ? "cbs" : "cbd"
        let cbsKey = op.reversed ? "cbd" : "cbs"
        capacitanceStore.commit(key: cgsKey, node1: gateIdx, node2: esIdx, capacitance: caps.cgs, state: state, integration: integration)
        capacitanceStore.commit(key: cgdKey, node1: gateIdx, node2: edIdx, capacitance: caps.cgd, state: state, integration: integration)
        capacitanceStore.commit(key: "cgb", node1: gateIdx, node2: bulkIdx, capacitance: caps.cgb, state: state, integration: integration)
        capacitanceStore.commit(key: cbdKey, node1: bulkIdx, node2: edIdx, capacitance: caps.cbd, state: state, integration: integration)
        capacitanceStore.commit(key: cbsKey, node1: bulkIdx, node2: esIdx, capacitance: caps.cbs, state: state, integration: integration)
    }

    public func noiseContributions(state: SolutionState, frequency: Double) -> [NoiseSource] {
        _ = frequency
        let op = operatingPoint(state: state)
        let effectiveDrain = op.reversed ? source : drain
        let effectiveSource = op.reversed ? drain : source
        return MOSFETNoiseModel.channelThermalNoiseSource(
            instanceName: instance.name,
            positiveNode: effectiveDrain,
            negativeNode: effectiveSource,
            gm: op.gm,
            gds: op.gds,
            temperatureKelvin: parameters.operatingTemperature
        )
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

    // MARK: - VoltageLimitingDevice

    /// Maximum Vgs change per NR iteration (V).
    private static let maxVgsStep: Double = 0.5
    /// Maximum Vds change per NR iteration (V).
    private static let maxVdsStep: Double = 1.0

    public func limitVoltages(solution: inout [Double], previousSolution: [Double]) {
        let vgNew = gateIdx.map { solution[$0] } ?? 0.0
        let vdNew = drainIdx.map { solution[$0] } ?? 0.0
        let vsNew = sourceIdx.map { solution[$0] } ?? 0.0

        let vgOld = gateIdx.map { previousSolution[$0] } ?? 0.0
        let vdOld = drainIdx.map { previousSolution[$0] } ?? 0.0
        let vsOld = sourceIdx.map { previousSolution[$0] } ?? 0.0

        let vgsNew = vgNew - vsNew
        let vgsOld = vgOld - vsOld
        let vdsNew = vdNew - vsNew
        let vdsOld = vdOld - vsOld

        var deltaVgs = vgsNew - vgsOld
        var deltaVds = vdsNew - vdsOld

        // Clamp Vgs change
        if abs(deltaVgs) > Self.maxVgsStep {
            deltaVgs = deltaVgs > 0 ? Self.maxVgsStep : -Self.maxVgsStep
        }
        // Clamp Vds change
        if abs(deltaVds) > Self.maxVdsStep {
            deltaVds = deltaVds > 0 ? Self.maxVdsStep : -Self.maxVdsStep
        }

        let vgsLimited = vgsOld + deltaVgs
        let vdsLimited = vdsOld + deltaVds

        let vgsCorrected = vgsLimited - vgsNew
        let vdsCorrected = vdsLimited - vdsNew

        if vgsCorrected != 0 || vdsCorrected != 0 {
            // Adjust gate for Vgs correction
            if let gIdx = gateIdx {
                solution[gIdx] += vgsCorrected
            }
            // Adjust drain for Vds correction
            if let dIdx = drainIdx {
                solution[dIdx] += vdsCorrected
            }
        }
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
        let surfacePotential = parameters.phi
        let sqrtPhi = sqrt(abs(surfacePotential))
        let phiMinusVbs = max(surfacePotential - vbs, 0.01)
        let vth = parameters.vto + parameters.gamma * (sqrt(phiMinusVbs) - sqrtPhi)

        // Smooth overdrive: continuous transition through cutoff (no hard if/else)
        let rawVgst = vgs - vth
        let vgst = Self.smoothClamp(rawVgst)
        let dvgst = Self.smoothClampDeriv(rawVgst) // d(vgst)/d(vgs)

        let ids: Double
        let gm: Double
        let gds: Double

        if vds < vgst {
            // Linear region: Ids = beta * (Vgst * Vds - 0.5 * Vds^2) * (1 + lambda * Vds)
            let clm = 1.0 + lambda * vds
            ids = beta * (vgst * vds - 0.5 * vds * vds) * clm
            // gm = dIds/dVgs = dIds/dVgst * dVgst/dVgs
            gm = beta * vds * clm * dvgst
            gds = beta * (vgst - vds) * clm
                    + beta * (vgst * vds - 0.5 * vds * vds) * lambda
        } else {
            // Saturation region: Ids = 0.5 * beta * Vgst^2 * (1 + lambda * Vds)
            let clm = 1.0 + lambda * vds
            ids = 0.5 * beta * vgst * vgst * clm
            // gm = dIds/dVgs = beta * Vgst * clm * dVgst/dVgs
            gm = beta * vgst * clm * dvgst
            gds = 0.5 * beta * vgst * vgst * lambda
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
                ids: ids, gm: gm, gds: effectiveGds, gmbs: gmbs,
                vgs: vgs, vds: vds, vbs: vbs, reversed: true
            )
        }
        return OperatingPointResult(
            ids: ids, gm: gm, gds: effectiveGds, gmbs: gmbs,
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
        // Fast path: use pre-resolved CSR indices for O(1) stamping (non-reversed case only)
        if !op.reversed, let sv = stamper.stampValue, csrIndices.dd != nil || csrIndices.ss != nil {
            // Combined Jacobian: J[D,D] = gds, J[S,S] = gds + gm + gmbs
            // J[D,S] = -gds - gm - gmbs, J[S,D] = -gds
            // J[D,G] = gm, J[S,G] = -gm
            // J[D,B] = gmbs, J[S,B] = -gmbs
            if let idx = csrIndices.dd { sv(idx, op.gds) }
            if let idx = csrIndices.ss { sv(idx, op.gds + op.gm + op.gmbs) }
            if let idx = csrIndices.ds { sv(idx, -op.gds - op.gm - op.gmbs) }
            if let idx = csrIndices.sd { sv(idx, -op.gds) }
            if let idx = csrIndices.dg { sv(idx, op.gm) }
            if let idx = csrIndices.sg { sv(idx, -op.gm) }
            if let idx = csrIndices.db { sv(idx, op.gmbs) }
            if let idx = csrIndices.sb { sv(idx, -op.gmbs) }
        } else {
            // Fallback to dictionary-based stamping (for reversed case or no CSR indices)
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
        }

        // Equivalent current source: Ieq = Ids - gm*Vgs - gds*Vds - gmbs*Vbs
        let ieq = op.ids - op.gm * op.vgs - op.gds * op.vds - op.gmbs * op.vbs

        // Use pre-resolved indices for RHS stamping
        let effectiveDrainIdx = op.reversed ? sourceIdx : drainIdx
        let effectiveSourceIdx = op.reversed ? drainIdx : sourceIdx

        if let dIdx = effectiveDrainIdx {
            stamper.stampRHS(dIdx, -ieq)
        }
        if let sIdx = effectiveSourceIdx {
            stamper.stampRHS(sIdx, ieq)
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

        // Channel capacitance depends on operating region
        let vgs = op.reversed ? (nodeVoltage(gateIdx, state) - nodeVoltage(drainIdx, state)) : (nodeVoltage(gateIdx, state) - nodeVoltage(sourceIdx, state))
        let vds = abs(nodeVoltage(drainIdx, state) - nodeVoltage(sourceIdx, state))

        let surfacePotential = parameters.phi
        let sqrtPhi = sqrt(abs(surfacePotential))
        let vbs = op.reversed ? (nodeVoltage(bulkIdx, state) - nodeVoltage(drainIdx, state)) : (nodeVoltage(bulkIdx, state) - nodeVoltage(sourceIdx, state))
        let phiMinusVbs = max(surfacePotential - vbs, 0.01)
        let vth = parameters.vto + parameters.gamma * (sqrt(phiMinusVbs) - sqrtPhi)

        let coxWL = cox * w * l
        let cgs: Double
        let cgd: Double
        let cgb: Double

        let vgst = vgs - vth
        if vgst <= 0 {
            // Cutoff: all channel capacitance goes to gate-bulk
            cgs = cgsOverlap
            cgd = cgdOverlap
            cgb = coxWL + cgbOverlap
        } else if vds < vgst {
            // Linear region
            let ratio1 = (vgst - vds) / (2.0 * vgst - vds)
            let ratio2 = vgst / (2.0 * vgst - vds)
            cgs = coxWL * 2.0 / 3.0 * (1.0 - ratio1 * ratio1) + cgsOverlap
            cgd = coxWL * 2.0 / 3.0 * (1.0 - ratio2 * ratio2) + cgdOverlap
            cgb = cgbOverlap
        } else {
            // Saturation: 2/3 of channel charge goes to gate-source
            cgs = 2.0 / 3.0 * coxWL + cgsOverlap
            cgd = cgdOverlap
            cgb = cgbOverlap
        }

        // Junction capacitances (voltage-dependent depletion model)
        let vbd = nodeVoltage(bulkIdx, state) - (op.reversed ? nodeVoltage(sourceIdx, state) : nodeVoltage(drainIdx, state))
        let vbsJunc = nodeVoltage(bulkIdx, state) - (op.reversed ? nodeVoltage(drainIdx, state) : nodeVoltage(sourceIdx, state))

        let cbd = junctionCapacitance(vj: vbd, area: parameters.ad, perimeter: parameters.pd)
        let cbs = junctionCapacitance(vj: vbsJunc, area: parameters.asrc, perimeter: parameters.ps)

        return MeyerCapacitances(cgs: cgs, cgd: cgd, cgb: cgb, cbd: cbd, cbs: cbs)
    }

    /// Compute voltage-dependent junction capacitance using the standard
    /// diode depletion model with linear extrapolation above 0.5*PB.
    private func junctionCapacitance(vj: Double, area: Double, perimeter: Double) -> Double {
        let pb = parameters.pb
        guard pb > 0 else { return 0 }

        let cjBottom: Double
        if parameters.cj > 0 && area > 0 {
            if vj < 0.5 * pb {
                cjBottom = parameters.cj * area / pow(1.0 - vj / pb, parameters.mj)
            } else {
                // Linear extrapolation above forward-bias threshold
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

    /// Stamp a capacitance as jωC admittance for AC analysis.
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

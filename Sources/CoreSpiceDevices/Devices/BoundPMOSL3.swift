import Foundation
import CoreSpiceIR

/// A PMOS Level 3 MOSFET bound to circuit nodes.
///
/// Adds mobility degradation (`theta`), DIBL (`eta`), and velocity
/// saturation (`kappa`, `vmax`) using source-referenced voltages.
public struct BoundPMOSL3: BoundDevice, VoltageLimitingDevice, TransientStateCommittingDevice, NoisyDevice, Sendable {

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
        stampDC(into: &stamper, state: state)

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
            positiveNode: effectiveSource,
            negativeNode: effectiveDrain,
            gm: op.gm,
            gds: op.gds,
            temperatureKelvin: parameters.operatingTemperature
        )
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

    private static let maxVgsStep: Double = 0.5
    private static let maxVdsStep: Double = 1.0

    public func limitVoltages(solution: inout [Double], previousSolution: [Double]) {
        let vgNew = gateIdx.map { solution[$0] } ?? 0.0
        let vdNew = drainIdx.map { solution[$0] } ?? 0.0
        let vsNew = sourceIdx.map { solution[$0] } ?? 0.0

        let vgOld = gateIdx.map { previousSolution[$0] } ?? 0.0
        let vdOld = drainIdx.map { previousSolution[$0] } ?? 0.0
        let vsOld = sourceIdx.map { previousSolution[$0] } ?? 0.0

        let vsgNew = vsNew - vgNew
        let vsgOld = vsOld - vgOld
        let vsdNew = vsNew - vdNew
        let vsdOld = vsOld - vdOld

        var deltaVsg = vsgNew - vsgOld
        var deltaVsd = vsdNew - vsdOld

        if abs(deltaVsg) > Self.maxVgsStep {
            deltaVsg = deltaVsg > 0 ? Self.maxVgsStep : -Self.maxVgsStep
        }
        if abs(deltaVsd) > Self.maxVdsStep {
            deltaVsd = deltaVsd > 0 ? Self.maxVdsStep : -Self.maxVdsStep
        }

        let vsgLimited = vsgOld + deltaVsg
        let vsdLimited = vsdOld + deltaVsd

        let vsgCorrected = vsgLimited - vsgNew
        let vsdCorrected = vsdLimited - vsdNew

        if vsgCorrected != 0 || vsdCorrected != 0 {
            if let gIdx = gateIdx {
                solution[gIdx] -= vsgCorrected
            }
            if let dIdx = drainIdx {
                solution[dIdx] -= vsdCorrected
            }
        }
    }

    // MARK: - Internal Model

    private struct OperatingPointResult {
        let isd: Double
        let gm: Double
        let gds: Double
        let gmbs: Double
        let vsg: Double
        let vsd: Double
        let vbs: Double
        let reversed: Bool
    }

    private func operatingPoint(state: SolutionState) -> OperatingPointResult {
        let vGate = nodeVoltage(gateIdx, state)
        let vDrain = nodeVoltage(drainIdx, state)
        let vSource = nodeVoltage(sourceIdx, state)
        let vBulk = nodeVoltage(bulkIdx, state)

        let rawVsg = vSource - vGate
        let rawVsd = vSource - vDrain
        let rawVbs = vSource - vBulk

        let reversed = rawVsd < 0
        let vsg: Double
        let vsd: Double
        let vbs: Double
        if reversed {
            vsd = -rawVsd
            vsg = vDrain - vGate
            vbs = vDrain - vBulk
        } else {
            vsd = rawVsd
            vsg = rawVsg
            vbs = rawVbs
        }

        let channel = MOSL3Channel(parameters: parameters, polarity: -1,
                                   gateBias: vsg, drainBias: vsd, bodyBias: vbs)
        return OperatingPointResult(
            isd: channel.current, gm: channel.gateDerivative,
            gds: channel.drainDerivative, gmbs: channel.bodyDerivative,
            vsg: vsg, vsd: vsd, vbs: vbs, reversed: reversed
        )
    }

    private func stampLinearized(into stamper: inout MatrixStamper, op: OperatingPointResult) {
        if !op.reversed, let sv = stamper.stampValue, csrIndices.ss != nil || csrIndices.dd != nil {
            if let idx = csrIndices.ss { sv(idx, op.gds + op.gm + op.gmbs) }
            if let idx = csrIndices.dd { sv(idx, op.gds) }
            if let idx = csrIndices.sd { sv(idx, -op.gds) }
            if let idx = csrIndices.ds { sv(idx, -op.gds - op.gm - op.gmbs) }
            if let idx = csrIndices.sg { sv(idx, -op.gm) }
            if let idx = csrIndices.dg { sv(idx, op.gm) }
            if let idx = csrIndices.sb { sv(idx, -op.gmbs) }
            if let idx = csrIndices.db { sv(idx, op.gmbs) }
        } else {
            let effectiveDrain = op.reversed ? source : drain
            let effectiveSource = op.reversed ? drain : source
            let dIdx = stamper.nodeIndex(effectiveDrain)
            let gIdx = stamper.nodeIndex(gate)
            let sIdx = stamper.nodeIndex(effectiveSource)
            let bIdx = stamper.nodeIndex(bulk)

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

        let ieq = op.isd - op.gm * op.vsg - op.gds * op.vsd - op.gmbs * op.vbs

        let effectiveDrainIdx = op.reversed ? sourceIdx : drainIdx
        let effectiveSourceIdx = op.reversed ? drainIdx : sourceIdx

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

        let cgsOverlap = (op.reversed ? parameters.cgdo : parameters.cgso) * w
        let cgdOverlap = (op.reversed ? parameters.cgso : parameters.cgdo) * w
        let cgbOverlap = parameters.cgbo * l

        let vsg = op.reversed ? (nodeVoltage(drainIdx, state) - nodeVoltage(gateIdx, state)) : (nodeVoltage(sourceIdx, state) - nodeVoltage(gateIdx, state))
        let vsd = abs(nodeVoltage(sourceIdx, state) - nodeVoltage(drainIdx, state))

        let vtpAbs = MOSL3Channel.threshold(
            parameters, polarity: -1, drainBias: vsd, bodyBias: op.vbs
        )

        let coxWL = cox * w * l
        let cgs: Double
        let cgd: Double
        let cgb: Double

        let vsgOverdrive = vsg - vtpAbs
        if vsgOverdrive <= 0 {
            cgs = cgsOverlap
            cgd = cgdOverlap
            cgb = coxWL + cgbOverlap
        } else {
            let vdsat = MOSL3Channel.saturationBias(parameters, overdrive: vsgOverdrive)

            if vsd < vdsat {
                let ratio1 = (vsgOverdrive - vsd) / (2.0 * vsgOverdrive - vsd)
                let ratio2 = vsgOverdrive / (2.0 * vsgOverdrive - vsd)
                cgs = coxWL * 2.0 / 3.0 * (1.0 - ratio1 * ratio1) + cgsOverlap
                cgd = coxWL * 2.0 / 3.0 * (1.0 - ratio2 * ratio2) + cgdOverlap
                cgb = cgbOverlap
            } else {
                cgs = 2.0 / 3.0 * coxWL + cgsOverlap
                cgd = cgdOverlap
                cgb = cgbOverlap
            }
        }

        let vbd = nodeVoltage(bulkIdx, state) - (op.reversed ? nodeVoltage(sourceIdx, state) : nodeVoltage(drainIdx, state))
        let vbsJunc = nodeVoltage(bulkIdx, state) - (op.reversed ? nodeVoltage(drainIdx, state) : nodeVoltage(sourceIdx, state))

        let cbd = junctionCapacitance(
            vj: -vbd, area: op.reversed ? parameters.asrc : parameters.ad,
            perimeter: op.reversed ? parameters.ps : parameters.pd
        )
        let cbs = junctionCapacitance(
            vj: -vbsJunc, area: op.reversed ? parameters.ad : parameters.asrc,
            perimeter: op.reversed ? parameters.pd : parameters.ps
        )

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

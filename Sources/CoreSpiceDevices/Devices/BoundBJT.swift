import Foundation
import CoreSpiceIR

/// A Bipolar Junction Transistor bound to circuit nodes.
///
/// Implements the Ebers-Moll model with:
/// - Transport model for collector and emitter currents
/// - Early effect (base-width modulation)
/// - Four operating regions: cutoff, forward active, reverse active, saturation
///
/// The device is linearised around the current operating point for
/// Newton-Raphson iteration.
public struct BoundBJT: BoundDevice, VoltageLimitingDevice, Sendable {

    public let instance: Instance
    private let collector: Node
    private let base: Node
    private let emitter: Node
    private let parameters: BJTModelParameters

    /// Pre-resolved matrix index for the collector node (nil for ground).
    private let collectorIdx: Int?
    /// Pre-resolved matrix index for the base node (nil for ground).
    private let baseIdx: Int?
    /// Pre-resolved matrix index for the emitter node (nil for ground).
    private let emitterIdx: Int?

    /// Convergence tolerance for terminal voltages (V).
    private static let voltageTolerance: Double = 1e-6

    /// Maximum exponential argument to prevent overflow.
    private static let maxExpArg: Double = 40.0

    /// Minimum conductance to ensure matrix non-singularity.
    private static let gmin: Double = 1e-12

    init(
        instance: Instance,
        collector: Node,
        base: Node,
        emitter: Node,
        collectorIdx: Int?,
        baseIdx: Int?,
        emitterIdx: Int?,
        parameters: BJTModelParameters
    ) {
        self.instance = instance
        self.collector = collector
        self.base = base
        self.emitter = emitter
        self.collectorIdx = collectorIdx
        self.baseIdx = baseIdx
        self.emitterIdx = emitterIdx
        self.parameters = parameters
    }

    // MARK: - Index-Based Voltage Helpers

    /// Returns the voltage at a node using a pre-resolved index, avoiding dictionary lookup.
    @inline(__always)
    private func nodeVoltage(_ idx: Int?, state: SolutionState) -> Double {
        if let idx { return state.value(at: idx) }
        return 0.0
    }

    // MARK: - BoundDevice

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        let op = operatingPoint(state: state)
        stampLinearized(into: &stamper, op: op, state: state)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        let op = operatingPoint(state: state)

        let cIdx = stamper.nodeIndex(collector)
        let bIdx = stamper.nodeIndex(base)
        let eIdx = stamper.nodeIndex(emitter)

        // Transconductance gm: dIc/dVbe
        if op.gm != 0 {
            if let cIdx, let bIdx {
                stamper.stampMatrix(cIdx, bIdx, op.gm, 0.0)
            }
            if let cIdx, let eIdx {
                stamper.stampMatrix(cIdx, eIdx, -op.gm, 0.0)
            }
            if let eIdx, let bIdx {
                stamper.stampMatrix(eIdx, bIdx, -op.gm, 0.0)
            }
            if let eIdx {
                stamper.stampMatrix(eIdx, eIdx, op.gm, 0.0)
            }
        }

        // Output conductance go: dIc/dVce
        if op.go != 0 {
            if let cIdx {
                stamper.stampMatrix(cIdx, cIdx, op.go, 0.0)
            }
            if let eIdx {
                stamper.stampMatrix(eIdx, eIdx, op.go, 0.0)
            }
            if let cIdx, let eIdx {
                stamper.stampMatrix(cIdx, eIdx, -op.go, 0.0)
                stamper.stampMatrix(eIdx, cIdx, -op.go, 0.0)
            }
        }

        // Input conductance gpi: dIb/dVbe
        if op.gpi != 0 {
            if let bIdx {
                stamper.stampMatrix(bIdx, bIdx, op.gpi, 0.0)
            }
            if let eIdx {
                stamper.stampMatrix(eIdx, eIdx, op.gpi, 0.0)
            }
            if let bIdx, let eIdx {
                stamper.stampMatrix(bIdx, eIdx, -op.gpi, 0.0)
                stamper.stampMatrix(eIdx, bIdx, -op.gpi, 0.0)
            }
        }

        // Base-collector junction conductance gmu: between B and C
        if op.gmu != 0 {
            if let bIdx {
                stamper.stampMatrix(bIdx, bIdx, op.gmu, 0.0)
            }
            if let cIdx {
                stamper.stampMatrix(cIdx, cIdx, op.gmu, 0.0)
            }
            if let bIdx, let cIdx {
                stamper.stampMatrix(bIdx, cIdx, -op.gmu, 0.0)
                stamper.stampMatrix(cIdx, bIdx, -op.gmu, 0.0)
            }
        }

        // Junction capacitance susceptance stamps
        let caps = bjtCapacitances(state: state)
        stampACCapacitance(into: &stamper, node1: bIdx, node2: eIdx, cap: caps.cbe, omega: omega)
        stampACCapacitance(into: &stamper, node1: bIdx, node2: cIdx, cap: caps.cbc, omega: omega)
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        // DC (quasi-static I-V) part
        stampDC(into: &stamper, state: state)

        // Junction capacitance companion models
        let caps = bjtCapacitances(state: state)

        let bIdx = stamper.nodeIndex(base)
        let eIdx = stamper.nodeIndex(emitter)
        let cIdx = stamper.nodeIndex(collector)

        // Cbe: between base and emitter
        stampTransientCapacitance(
            into: &stamper, node1: bIdx, node2: eIdx,
            cap: caps.cbe, state: state, integration: integration
        )

        // Cbc: between base and collector
        stampTransientCapacitance(
            into: &stamper, node1: bIdx, node2: cIdx,
            cap: caps.cbc, state: state, integration: integration
        )
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        let vbeNew = voltageVbe(state: state)
        let vbeOld = voltageVbe(state: previousState)
        let vbcNew = voltageVbc(state: state)
        let vbcOld = voltageVbc(state: previousState)

        let deltaVbe = abs(vbeNew - vbeOld)
        let deltaVbc = abs(vbcNew - vbcOld)
        let maxDelta = max(deltaVbe, deltaVbc)

        if maxDelta < Self.voltageTolerance {
            return .converged
        }
        return .notConverged(maxDelta: maxDelta, deviceName: instance.name)
    }

    // MARK: - Internal Model

    private struct OperatingPointResult {
        let ic: Double   // collector current
        let ib: Double   // base current
        let ie: Double   // emitter current
        let gm: Double   // transconductance dIc/dVbe
        let go: Double   // output conductance dIc/dVce
        let gpi: Double  // input conductance dIb/dVbe
        let gmu: Double  // reverse transconductance dIc/dVbc
        let vbe: Double  // base-emitter voltage
        let vbc: Double  // base-collector voltage
        let vce: Double  // collector-emitter voltage
    }

    /// Returns the base-emitter voltage, accounting for polarity.
    private func voltageVbe(state: SolutionState) -> Double {
        let vb = nodeVoltage(baseIdx, state: state)
        let ve = nodeVoltage(emitterIdx, state: state)
        switch parameters.polarity {
        case .npn: return vb - ve
        case .pnp: return ve - vb
        }
    }

    /// Returns the base-collector voltage, accounting for polarity.
    private func voltageVbc(state: SolutionState) -> Double {
        let vb = nodeVoltage(baseIdx, state: state)
        let vc = nodeVoltage(collectorIdx, state: state)
        switch parameters.polarity {
        case .npn: return vb - vc
        case .pnp: return vc - vb
        }
    }

    /// Returns the collector-emitter voltage, accounting for polarity.
    private func voltageVce(state: SolutionState) -> Double {
        let vc = nodeVoltage(collectorIdx, state: state)
        let ve = nodeVoltage(emitterIdx, state: state)
        switch parameters.polarity {
        case .npn: return vc - ve
        case .pnp: return ve - vc
        }
    }

    private func operatingPoint(state: SolutionState) -> OperatingPointResult {
        let vbe = voltageVbe(state: state)
        let vbc = voltageVbc(state: state)
        let vce = voltageVce(state: state)

        let vt = parameters.thermalVoltage
        let nf = parameters.forwardEmissionCoefficient
        let nr = parameters.reverseEmissionCoefficient
        let isat = parameters.saturationCurrent
        let bf = parameters.forwardBeta
        let br = parameters.reverseBeta
        let vaf = parameters.forwardEarlyVoltage
        // let var_ = parameters.reverseEarlyVoltage  // Reserved for future use

        let nfVt = nf * vt
        let nrVt = nr * vt

        // Limit exponential arguments
        let expArgBE = min(vbe / nfVt, Self.maxExpArg)
        let expArgBC = min(vbc / nrVt, Self.maxExpArg)

        let expBE = exp(expArgBE)
        let expBC = exp(expArgBC)

        // Ebers-Moll transport currents
        // Icc = Is * (exp(Vbe/nfVt) - 1) : forward collector current
        // Iec = Is * (exp(Vbc/nrVt) - 1) : reverse emitter current
        let icc = isat * (expBE - 1)
        let iec = isat * (expBC - 1)

        // Collector and emitter currents (transport model)
        // Ic = Icc - Iec/br
        // Ie = -Icc/bf + Iec
        var ic = icc - iec / br
        let ie = -icc / bf + iec

        // Early effect (base-width modulation)
        var earlyFactor = 1.0
        if vaf.isFinite && vaf > 0 {
            earlyFactor = 1.0 + vce / vaf
            ic *= earlyFactor
        }

        // Base current: sum of forward and reverse base recombination
        let ib = icc / bf + iec / br

        // Small-signal parameters
        // gm = dIc/dVbe = (Is/nfVt) * exp(Vbe/nfVt) * earlyFactor
        var gm = isat / nfVt * expBE * earlyFactor

        // go = dIc/dVce = Ic / Vaf (Early effect)
        var go = 0.0
        if vaf.isFinite && vaf > 0 {
            go = abs(ic) / vaf
        }

        // gpi = dIb/dVbe = Is/(bf*nfVt)*exp(Vbe/nfVt)
        // Base current Ib = Icc/bf does NOT depend on Vce, so no Early factor.
        var gpi = isat / (bf * nfVt) * expBE

        // gmu = dIc/dVbc (reverse transconductance for saturation)
        var gmu = isat / (br * nrVt) * expBC

        // Add gmin for numerical stability
        gm = max(gm, Self.gmin)
        gpi = max(gpi, Self.gmin)
        gmu = max(gmu, Self.gmin)
        go += Self.gmin

        return OperatingPointResult(
            ic: ic, ib: ib, ie: ie,
            gm: gm, go: go, gpi: gpi, gmu: gmu,
            vbe: vbe, vbc: vbc, vce: vce
        )
    }

    // MARK: - VoltageLimitingDevice

    public func limitVoltages(solution: inout [Double], previousSolution: [Double]) {
        let nfVt = parameters.forwardEmissionCoefficient * parameters.thermalVoltage
        let nrVt = parameters.reverseEmissionCoefficient * parameters.thermalVoltage
        let isat = parameters.saturationCurrent
        let isNPN = parameters.polarity == .npn

        let vbNew = baseIdx.map { solution[$0] } ?? 0.0
        let vcNew = collectorIdx.map { solution[$0] } ?? 0.0
        let veNew = emitterIdx.map { solution[$0] } ?? 0.0

        let vbOld = baseIdx.map { previousSolution[$0] } ?? 0.0
        let vcOld = collectorIdx.map { previousSolution[$0] } ?? 0.0
        let veOld = emitterIdx.map { previousSolution[$0] } ?? 0.0

        // Compute junction voltages accounting for polarity
        let vbeNew: Double
        let vbeOld: Double
        let vbcNew: Double
        let vbcOld: Double

        if isNPN {
            vbeNew = vbNew - veNew
            vbeOld = vbOld - veOld
            vbcNew = vbNew - vcNew
            vbcOld = vbOld - vcOld
        } else {
            vbeNew = veNew - vbNew
            vbeOld = veOld - vbOld
            vbcNew = vcNew - vbNew
            vbcOld = vcOld - vbOld
        }

        // Limit BE junction
        let vbeLimited = PNJunctionLimiter.limit(vNew: vbeNew, vOld: vbeOld, vt: nfVt, isat: isat)
        // Limit BC junction
        let vbcLimited = PNJunctionLimiter.limit(vNew: vbcNew, vOld: vbcOld, vt: nrVt, isat: isat)

        let beCorrection = vbeLimited - vbeNew
        let bcCorrection = vbcLimited - vbcNew

        if beCorrection != 0 || bcCorrection != 0 {
            // Fix emitter node, adjust base and collector to achieve
            // the desired junction voltage corrections exactly.
            //
            // NPN: Vbe = Vb - Ve, Vbc = Vb - Vc
            //   ΔVb = beCorrection
            //   ΔVc = beCorrection - bcCorrection
            //
            // PNP: Vbe = Ve - Vb, Vbc = Vc - Vb
            //   ΔVb = -beCorrection
            //   ΔVc = bcCorrection - beCorrection
            if isNPN {
                if let bIdx = baseIdx {
                    solution[bIdx] += beCorrection
                }
                if let cIdx = collectorIdx {
                    solution[cIdx] += beCorrection - bcCorrection
                }
            } else {
                if let bIdx = baseIdx {
                    solution[bIdx] -= beCorrection
                }
                if let cIdx = collectorIdx {
                    solution[cIdx] += bcCorrection - beCorrection
                }
            }
        }
    }

    // MARK: - BJT Capacitance Model

    private struct BJTCapacitances {
        let cbe: Double  // total base-emitter capacitance (depletion + diffusion)
        let cbc: Double  // total base-collector capacitance (depletion + diffusion)
    }

    /// Computes voltage-dependent junction capacitances.
    ///
    /// Each junction has two components:
    /// - Depletion capacitance: `Cj = Cj0 / (1 - V/Vj)^M` (linear extrapolation above 0.5*Vj)
    /// - Diffusion capacitance: `Cd = transit_time * g` (charge storage from minority carriers)
    private func bjtCapacitances(state: SolutionState) -> BJTCapacitances {
        let op = operatingPoint(state: state)

        // --- Base-Emitter junction ---
        let cje0 = parameters.baseEmitterCapacitance
        let vje = parameters.baseEmitterPotential
        let mje = parameters.baseEmitterGradingCoeff
        let tf = parameters.forwardTransitTime

        // Depletion capacitance
        let cjeDepl: Double
        if cje0 > 0 {
            if op.vbe < 0.5 * vje {
                cjeDepl = cje0 / pow(1.0 - op.vbe / vje, mje)
            } else {
                // Linear extrapolation above 0.5*Vje to prevent singularity
                let cHalf = cje0 / pow(0.5, mje)
                let slope = cHalf * mje / vje
                cjeDepl = cHalf + slope * (op.vbe - 0.5 * vje)
            }
        } else {
            cjeDepl = 0
        }

        // Forward diffusion capacitance: Cd_f = tau_f * gm
        let cdF = tf * op.gm

        // --- Base-Collector junction ---
        let cjc0 = parameters.baseCollectorCapacitance
        let vjc = parameters.baseCollectorPotential
        let mjc = parameters.baseCollectorGradingCoeff
        let tr = parameters.reverseTransitTime

        // Depletion capacitance
        let cjcDepl: Double
        if cjc0 > 0 {
            if op.vbc < 0.5 * vjc {
                cjcDepl = cjc0 / pow(1.0 - op.vbc / vjc, mjc)
            } else {
                let cHalf = cjc0 / pow(0.5, mjc)
                let slope = cHalf * mjc / vjc
                cjcDepl = cHalf + slope * (op.vbc - 0.5 * vjc)
            }
        } else {
            cjcDepl = 0
        }

        // Reverse diffusion capacitance: Cd_r = tau_r * gmu
        let cdR = tr * op.gmu

        return BJTCapacitances(
            cbe: cjeDepl + cdF,
            cbc: cjcDepl + cdR
        )
    }

    // MARK: - Capacitance Stamping Helpers

    /// Stamp a capacitance as jomegaC admittance for AC analysis.
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

    /// Stamp a capacitance companion model for transient analysis.
    ///
    /// Uses backward Euler or trapezoidal integration. Trapezoidal
    /// includes the previous capacitor current for O(h^2) accuracy.
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

        // Conductance stamp
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

        // History current source
        if let n1 = node1 {
            stamper.stampRHS(n1, ieq)
        }
        if let n2 = node2 {
            stamper.stampRHS(n2, -ieq)
        }
    }

    /// Stamp the linearized model around the operating point.
    ///
    /// The Jacobian w.r.t. external node voltages is identical for NPN and PNP
    /// because the polarity flips in both currents and voltages cancel out.
    /// Only the RHS equivalent current sources need a sign flip for PNP.
    ///
    /// SPICE3F5 Jacobian (matches AC stamps):
    ///   J[C,B] = gm - gmu    J[C,C] = go + gmu    J[C,E] = -gm - go
    ///   J[B,B] = gpi + gmu   J[B,C] = -gmu        J[B,E] = -gpi
    ///   J[E,B] = -gm - gpi   J[E,C] = -go         J[E,E] = gm + gpi + go
    private func stampLinearized(into stamper: inout MatrixStamper, op: OperatingPointResult, state: SolutionState) {
        let cIdx = stamper.nodeIndex(collector)
        let bIdx = stamper.nodeIndex(base)
        let eIdx = stamper.nodeIndex(emitter)

        let sign: Double = parameters.polarity == .npn ? 1.0 : -1.0

        // Transconductance gm: Ic depends on Vbe (no sign needed)
        if op.gm != 0 {
            if let cIdx, let bIdx {
                stamper.stampMatrix(cIdx, bIdx, op.gm)
            }
            if let cIdx, let eIdx {
                stamper.stampMatrix(cIdx, eIdx, -op.gm)
            }
            if let eIdx, let bIdx {
                stamper.stampMatrix(eIdx, bIdx, -op.gm)
            }
            if let eIdx {
                stamper.stampMatrix(eIdx, eIdx, op.gm)
            }
        }

        // Output conductance go: between C and E (no sign needed)
        if op.go != 0 {
            if let cIdx {
                stamper.stampMatrix(cIdx, cIdx, op.go)
            }
            if let eIdx {
                stamper.stampMatrix(eIdx, eIdx, op.go)
            }
            if let cIdx, let eIdx {
                stamper.stampMatrix(cIdx, eIdx, -op.go)
                stamper.stampMatrix(eIdx, cIdx, -op.go)
            }
        }

        // Input conductance gpi: between B and E (no sign needed)
        if op.gpi != 0 {
            if let bIdx {
                stamper.stampMatrix(bIdx, bIdx, op.gpi)
            }
            if let eIdx {
                stamper.stampMatrix(eIdx, eIdx, op.gpi)
            }
            if let bIdx, let eIdx {
                stamper.stampMatrix(bIdx, eIdx, -op.gpi)
                stamper.stampMatrix(eIdx, bIdx, -op.gpi)
            }
        }

        // Reverse transconductance gmu: between B and C (no sign needed)
        // gmu stamps in B and C rows — NOT E row (matches AC stamps and SPICE3F5)
        if op.gmu != 0 {
            if let bIdx {
                stamper.stampMatrix(bIdx, bIdx, op.gmu)
            }
            if let cIdx {
                stamper.stampMatrix(cIdx, cIdx, op.gmu)
            }
            if let bIdx, let cIdx {
                stamper.stampMatrix(bIdx, cIdx, -op.gmu)
                stamper.stampMatrix(cIdx, bIdx, -op.gmu)
            }
        }

        // Equivalent current sources from linearization
        // In direct NR form G*x = b, RHS = conductance_part - I_device
        // SPICE3F5: rhs[C] += (-ic + gm*vbe + go*vce + gmu*vbc) = -icq
        // Terminal current = sign * internal current (sign = -1 for PNP)
        let icq = sign * (op.ic - op.gm * op.vbe - op.go * op.vce + op.gmu * op.vbc)
        let ibq = sign * (op.ib - op.gpi * op.vbe - op.gmu * op.vbc)

        if let cIdx {
            stamper.stampRHS(cIdx, -icq)
        }
        if let eIdx {
            stamper.stampRHS(eIdx, icq + ibq)
        }
        if let bIdx {
            stamper.stampRHS(bIdx, -ibq)
        }
    }
}

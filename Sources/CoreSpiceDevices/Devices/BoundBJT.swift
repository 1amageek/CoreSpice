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
public struct BoundBJT: BoundDevice, Sendable {

    public let instance: Instance
    private let collector: Node
    private let base: Node
    private let emitter: Node
    private let parameters: BJTModelParameters

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
        parameters: BJTModelParameters
    ) {
        self.instance = instance
        self.collector = collector
        self.base = base
        self.emitter = emitter
        self.parameters = parameters
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

        // Reverse transconductance gmu: dIc/dVbc (for saturation region)
        if op.gmu != 0 {
            if let cIdx, let bIdx {
                stamper.stampMatrix(cIdx, bIdx, -op.gmu, 0.0)
            }
            if let cIdx {
                stamper.stampMatrix(cIdx, cIdx, op.gmu, 0.0)
            }
        }
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        // For Level 1 without detailed capacitance model, transient stamp
        // is the same as DC (quasi-static approximation).
        stampDC(into: &stamper, state: state)
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
        let vb = state.voltage(at: base)
        let ve = state.voltage(at: emitter)
        switch parameters.polarity {
        case .npn: return vb - ve
        case .pnp: return ve - vb
        }
    }

    /// Returns the base-collector voltage, accounting for polarity.
    private func voltageVbc(state: SolutionState) -> Double {
        let vb = state.voltage(at: base)
        let vc = state.voltage(at: collector)
        switch parameters.polarity {
        case .npn: return vb - vc
        case .pnp: return vc - vb
        }
    }

    /// Returns the collector-emitter voltage, accounting for polarity.
    private func voltageVce(state: SolutionState) -> Double {
        let vc = state.voltage(at: collector)
        let ve = state.voltage(at: emitter)
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

        // Base current from KCL: Ib = Ie - Ic
        let ib = ie - ic

        // Small-signal parameters
        // gm = dIc/dVbe = (Is/nfVt) * exp(Vbe/nfVt) * earlyFactor
        var gm = isat / nfVt * expBE * earlyFactor

        // go = dIc/dVce = Ic / Vaf (Early effect)
        var go = 0.0
        if vaf.isFinite && vaf > 0 {
            go = abs(ic) / vaf
        }

        // gpi = dIb/dVbe ≈ gm / bf
        var gpi = gm / bf

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

    /// Stamp the linearized model around the operating point.
    ///
    /// The Newton-Raphson linearization for collector current:
    ///   Ic = Ic0 + gm*(Vbe - Vbe0) + go*(Vce - Vce0) - gmu*(Vbc - Vbc0)
    ///
    /// This is stamped as conductance stamps plus equivalent current sources.
    private func stampLinearized(into stamper: inout MatrixStamper, op: OperatingPointResult, state: SolutionState) {
        let cIdx = stamper.nodeIndex(collector)
        let bIdx = stamper.nodeIndex(base)
        let eIdx = stamper.nodeIndex(emitter)

        // For PNP, we need to flip the sign of currents
        let sign: Double = parameters.polarity == .npn ? 1.0 : -1.0

        // Transconductance gm: Ic depends on Vbe
        // Stamp: cIdx += gm*(vb - ve), eIdx -= gm*(vb - ve)
        if op.gm != 0 {
            if let cIdx, let bIdx {
                stamper.stampMatrix(cIdx, bIdx, sign * op.gm)
            }
            if let cIdx, let eIdx {
                stamper.stampMatrix(cIdx, eIdx, -sign * op.gm)
            }
            if let eIdx, let bIdx {
                stamper.stampMatrix(eIdx, bIdx, -sign * op.gm)
            }
            if let eIdx {
                stamper.stampMatrix(eIdx, eIdx, sign * op.gm)
            }
        }

        // Output conductance go: between C and E
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

        // Input conductance gpi: between B and E
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

        // Reverse transconductance gmu: Ic depends on Vbc
        if op.gmu != 0 {
            if let cIdx, let bIdx {
                stamper.stampMatrix(cIdx, bIdx, -sign * op.gmu)
            }
            if let cIdx {
                stamper.stampMatrix(cIdx, cIdx, sign * op.gmu)
            }
            if let eIdx, let bIdx {
                stamper.stampMatrix(eIdx, bIdx, sign * op.gmu)
            }
            if let eIdx, let cIdx {
                stamper.stampMatrix(eIdx, cIdx, -sign * op.gmu)
            }
        }

        // Equivalent current sources from linearization
        // Icq = Ic - gm*Vbe - go*Vce + gmu*Vbc
        let icq = sign * op.ic - op.gm * op.vbe - op.go * op.vce + op.gmu * op.vbc
        // Ibq = Ib - gpi*Vbe
        let ibq = sign * op.ib - op.gpi * op.vbe

        // Stamp RHS: current enters collector, leaves emitter
        // For base: current enters base
        if let cIdx {
            stamper.stampRHS(cIdx, icq)
        }
        if let eIdx {
            stamper.stampRHS(eIdx, -icq - ibq)
        }
        if let bIdx {
            stamper.stampRHS(bIdx, ibq)
        }
    }
}

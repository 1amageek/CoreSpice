import Foundation
import CoreSpiceIR

/// A PN junction diode bound to circuit nodes.
///
/// Implements the Shockley diode equation with:
/// - Exponential I-V characteristic in forward bias
/// - Reverse saturation current in reverse bias
/// - Junction capacitance for transient analysis
/// - Voltage limiting to prevent numerical overflow
public struct BoundDiode: BoundDevice, VoltageLimitingDevice, Sendable {

    public let instance: Instance
    private let anode: Node
    private let cathode: Node
    private let parameters: DiodeModelParameters

    /// Pre-resolved matrix index for the anode node (nil for ground).
    private let anodeIdx: Int?
    /// Pre-resolved matrix index for the cathode node (nil for ground).
    private let cathodeIdx: Int?

    /// Convergence tolerance for diode voltage (V).
    private static let voltageTolerance: Double = 1e-6

    /// Maximum exponential argument to prevent overflow.
    private static let maxExpArg: Double = 40.0

    /// Minimum conductance to ensure matrix non-singularity.
    private static let gmin: Double = 1e-12

    init(
        instance: Instance,
        anode: Node,
        cathode: Node,
        anodeIdx: Int?,
        cathodeIdx: Int?,
        parameters: DiodeModelParameters
    ) {
        self.instance = instance
        self.anode = anode
        self.cathode = cathode
        self.anodeIdx = anodeIdx
        self.cathodeIdx = cathodeIdx
        self.parameters = parameters
    }

    // MARK: - Index-Based Voltage Helpers

    /// Returns the voltage at a node using a pre-resolved index, avoiding dictionary lookup.
    @inline(__always)
    private func nodeVoltage(_ idx: Int?, state: SolutionState) -> Double {
        if let idx { return state.value(at: idx) }
        return 0.0
    }

    /// Returns the previous voltage at a node using a pre-resolved index.
    @inline(__always)
    private func nodePreviousVoltage(_ idx: Int?, state: SolutionState) -> Double {
        if let idx { return state.previousValue(at: idx) }
        return 0.0
    }

    /// Returns the diode voltage (anode - cathode) from the current state.
    @inline(__always)
    private func diodeVoltage(state: SolutionState) -> Double {
        nodeVoltage(anodeIdx, state: state) - nodeVoltage(cathodeIdx, state: state)
    }

    /// Returns the diode voltage (anode - cathode) from the previous state.
    @inline(__always)
    private func diodePreviousVoltage(state: SolutionState) -> Double {
        nodePreviousVoltage(anodeIdx, state: state) - nodePreviousVoltage(cathodeIdx, state: state)
    }

    // MARK: - BoundDevice

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        let op = operatingPoint(state: state)
        stampLinearized(into: &stamper, op: op)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        let op = operatingPoint(state: state)

        // Small-signal conductance
        let aIdx = stamper.nodeIndex(anode)
        let cIdx = stamper.nodeIndex(cathode)

        // Conductance stamp
        if op.gd != 0 {
            if let aIdx {
                stamper.stampMatrix(aIdx, aIdx, op.gd, 0.0)
            }
            if let cIdx {
                stamper.stampMatrix(cIdx, cIdx, op.gd, 0.0)
            }
            if let aIdx, let cIdx {
                stamper.stampMatrix(aIdx, cIdx, -op.gd, 0.0)
                stamper.stampMatrix(cIdx, aIdx, -op.gd, 0.0)
            }
        }

        // Junction capacitance: depletion + diffusion (susceptance = jωC)
        let cjDepl = junctionCapacitance(vd: op.vd)
        let cDiff = parameters.transitTime * op.gd
        let cj = cjDepl + cDiff
        if cj > 0 {
            let susceptance = omega * cj
            if let aIdx {
                stamper.stampMatrix(aIdx, aIdx, 0.0, susceptance)
            }
            if let cIdx {
                stamper.stampMatrix(cIdx, cIdx, 0.0, susceptance)
            }
            if let aIdx, let cIdx {
                stamper.stampMatrix(aIdx, cIdx, 0.0, -susceptance)
                stamper.stampMatrix(cIdx, aIdx, 0.0, -susceptance)
            }
        }
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        // DC part (I-V linearization)
        stampDC(into: &stamper, state: state)

        // Junction capacitance companion model: depletion + diffusion
        let op = operatingPoint(state: state)
        let cjDepl = junctionCapacitance(vd: op.vd)
        let cDiff = parameters.transitTime * op.gd
        let cj = cjDepl + cDiff
        guard cj > 0 else { return }

        let aIdx = stamper.nodeIndex(anode)
        let cIdx = stamper.nodeIndex(cathode)

        stampTransientCapacitance(
            into: &stamper,
            node1: aIdx, node2: cIdx,
            cap: cj,
            state: state,
            integration: integration
        )
    }

    /// Stamp a capacitance companion model for transient analysis.
    ///
    /// - Backward Euler: `Geq = C/dt`, `Ieq = Geq * Vprev`
    /// - Trapezoidal: `Geq = 2C/dt`, `Ieq = Geq * Vprev + I_cap_prev`
    ///   where `I_cap_prev = C * (Vprev - Vprevprev) / dtPrev`
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

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        let vdNew = diodeVoltage(state: state)
        let vdOld = diodeVoltage(state: previousState)
        let delta = abs(vdNew - vdOld)

        if delta < Self.voltageTolerance {
            return .converged
        }
        return .notConverged(maxDelta: delta, deviceName: instance.name)
    }

    // MARK: - Internal Model

    private struct OperatingPointResult {
        let id: Double   // diode current
        let gd: Double   // small-signal conductance
        let vd: Double   // diode voltage
    }

    private func operatingPoint(state: SolutionState) -> OperatingPointResult {
        let vd = diodeVoltage(state: state)
        let vt = parameters.thermalVoltage
        let n = parameters.emissionCoefficient
        let isat = parameters.saturationCurrent

        let nvt = n * vt

        // Calculate current and conductance
        let id: Double
        let gd: Double

        if vd >= -5 * nvt {
            // Forward and moderate reverse bias: Shockley equation
            // Limit exponential argument to prevent overflow
            let expArg = min(vd / nvt, Self.maxExpArg)
            let expVal = exp(expArg)

            id = isat * (expVal - 1.0)
            gd = isat / nvt * expVal + Self.gmin
        } else if vd >= -parameters.breakdownVoltage {
            // Deep reverse bias (before breakdown)
            id = -isat
            gd = isat / nvt + Self.gmin
        } else {
            // Reverse breakdown region
            // Use exponential model for soft breakdown
            let vbr = parameters.breakdownVoltage
            let ibv = parameters.breakdownCurrent
            let vBreak = vd + vbr

            // Breakdown current: exponentially increasing past BV
            let breakdownExp = exp((-vBreak - vbr) / nvt)
            id = -isat - ibv * breakdownExp
            gd = ibv / nvt * breakdownExp + Self.gmin
        }

        return OperatingPointResult(id: id, gd: gd, vd: vd)
    }

    /// Calculate voltage-dependent junction capacitance.
    ///
    /// Uses the standard SPICE model:
    /// - Reverse bias: Cj = Cjo / (1 - Vd/Vj)^m
    /// - Forward bias: Linear extrapolation to prevent singularity
    private func junctionCapacitance(vd: Double) -> Double {
        let cjo = parameters.junctionCapacitance
        if cjo == 0 { return 0 }

        let vj = parameters.junctionPotential
        let m = parameters.gradingCoefficient

        if vd < 0.5 * vj {
            // Reverse and low forward bias: standard model
            return cjo / pow(1.0 - vd / vj, m)
        } else {
            // Forward bias: linear extrapolation to avoid singularity
            // C = Cjo * (1 + m * vd / vj) when vd > 0.5*vj
            let c_half = cjo / pow(0.5, m)
            let slope = c_half * m / (vj * 0.5)
            return c_half + slope * (vd - 0.5 * vj)
        }
    }

    // MARK: - VoltageLimitingDevice

    public func limitVoltages(solution: inout [Double], previousSolution: [Double]) {
        let vt = parameters.emissionCoefficient * parameters.thermalVoltage
        let isat = parameters.saturationCurrent

        let vaNew = anodeIdx.map { solution[$0] } ?? 0.0
        let vcNew = cathodeIdx.map { solution[$0] } ?? 0.0
        let vaOld = anodeIdx.map { previousSolution[$0] } ?? 0.0
        let vcOld = cathodeIdx.map { previousSolution[$0] } ?? 0.0

        let vdNew = vaNew - vcNew
        let vdOld = vaOld - vcOld

        let vdLimited = PNJunctionLimiter.limit(vNew: vdNew, vOld: vdOld, vt: vt, isat: isat)

        if vdLimited != vdNew {
            let correction = vdLimited - vdNew
            if let aIdx = anodeIdx {
                solution[aIdx] += correction
            }
        }
    }

    /// Stamp the linearized model around the operating point.
    ///
    /// Newton-Raphson linearization:
    ///   I_stamp = Id0 + gd * (Vd - Vd0)
    ///           = gd * Vd + (Id0 - gd * Vd0)
    ///
    /// The last term is the equivalent current source (RHS).
    private func stampLinearized(into stamper: inout MatrixStamper, op: OperatingPointResult) {
        let aIdx = stamper.nodeIndex(anode)
        let cIdx = stamper.nodeIndex(cathode)

        // Conductance stamp
        if let aIdx {
            stamper.stampMatrix(aIdx, aIdx, op.gd)
        }
        if let cIdx {
            stamper.stampMatrix(cIdx, cIdx, op.gd)
        }
        if let aIdx, let cIdx {
            stamper.stampMatrix(aIdx, cIdx, -op.gd)
            stamper.stampMatrix(cIdx, aIdx, -op.gd)
        }

        // Equivalent current source: Ieq = Id - gd * Vd
        let ieq = op.id - op.gd * op.vd

        // Current flows from anode to cathode
        if let aIdx {
            stamper.stampRHS(aIdx, -ieq)
        }
        if let cIdx {
            stamper.stampRHS(cIdx, ieq)
        }
    }
}

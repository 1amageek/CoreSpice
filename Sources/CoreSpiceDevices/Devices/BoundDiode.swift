import Foundation
import CoreSpiceIR

/// A PN junction diode bound to circuit nodes.
///
/// Implements the Shockley diode equation with:
/// - Exponential I-V characteristic in forward bias
/// - Reverse saturation current in reverse bias
/// - Junction capacitance for transient analysis
/// - Voltage limiting to prevent numerical overflow
public struct BoundDiode: BoundDevice, Sendable {

    public let instance: Instance
    private let anode: Node
    private let cathode: Node
    private let parameters: DiodeModelParameters

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
        parameters: DiodeModelParameters
    ) {
        self.instance = instance
        self.anode = anode
        self.cathode = cathode
        self.parameters = parameters
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

        // Junction capacitance (susceptance = jωC)
        let cj = junctionCapacitance(vd: op.vd)
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
        // DC part
        stampDC(into: &stamper, state: state)

        // Junction capacitance companion model
        let op = operatingPoint(state: state)
        let cj = junctionCapacitance(vd: op.vd)

        if cj > 0 {
            // Companion model: geq = coefficient * C
            let geq = integration.coefficient * cj

            // Stamp equivalent conductance
            stamper.stampConductance(node1: anode, node2: cathode, conductance: geq)

            // Equivalent current source based on previous voltage
            let vPrev = state.previousVoltage(at: anode) - state.previousVoltage(at: cathode)
            let ieq = geq * vPrev

            let aIdx = stamper.nodeIndex(anode)
            let cIdx = stamper.nodeIndex(cathode)

            if let aIdx {
                stamper.stampRHS(aIdx, ieq)
            }
            if let cIdx {
                stamper.stampRHS(cIdx, -ieq)
            }
        }
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        let vdNew = state.voltage(at: anode) - state.voltage(at: cathode)
        let vdOld = previousState.voltage(at: anode) - previousState.voltage(at: cathode)
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
        let vd = state.voltage(at: anode) - state.voltage(at: cathode)
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
            let slope = c_half * m / vj
            return c_half + slope * (vd - 0.5 * vj)
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

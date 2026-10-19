import Foundation
import CoreSpiceIR
import CoreSpiceDiodeContracts

/// A PN junction diode bound to circuit nodes.
///
/// Implements the Shockley diode equation with:
/// - Exponential I-V characteristic in forward bias
/// - Reverse saturation current in reverse bias
/// - Junction capacitance for transient analysis
/// - Voltage limiting to prevent numerical overflow
public struct BoundDiode: BoundDevice, VoltageLimitingDevice, TransientSessionDevice, NoisyDevice, Sendable {

    public let instance: Instance
    private let anode: Node
    private let cathode: Node
    private let parameters: DiodeModelParameters
    private let effectiveSaturationCurrent: Double
    public let preparationReceipt: DiodePreparationReceipt

    /// Pre-resolved matrix index for the anode node (nil for ground).
    private let anodeIdx: Int?
    /// Pre-resolved matrix index for the cathode node (nil for ground).
    private let cathodeIdx: Int?

    /// Pre-resolved CSR value indices for O(1) stamping.
    private let stampAA: Int?
    private let stampCC: Int?
    private let stampAC: Int?
    private let stampCA: Int?
    private let history: DiodeTransientHistory
    private let breakdownAmplitude: Double?

    /// Convergence tolerance for diode voltage (V).
    private static let voltageTolerance: Double = 1e-6

    init(
        instance: Instance,
        anode: Node,
        cathode: Node,
        anodeIdx: Int?,
        cathodeIdx: Int?,
        parameters: DiodeModelParameters,
        effectiveSaturationCurrent: Double,
        preparationReceipt: DiodePreparationReceipt,
        breakdownAmplitude: Double?,
        stampAA: Int? = nil,
        stampCC: Int? = nil,
        stampAC: Int? = nil,
        stampCA: Int? = nil
    ) {
        self.instance = instance
        self.anode = anode
        self.cathode = cathode
        self.anodeIdx = anodeIdx
        self.cathodeIdx = cathodeIdx
        self.parameters = parameters
        self.effectiveSaturationCurrent = effectiveSaturationCurrent
        self.preparationReceipt = preparationReceipt
        self.stampAA = stampAA
        self.stampCC = stampCC
        self.stampAC = stampAC
        self.stampCA = stampCA
        self.history = DiodeTransientHistory()
        self.breakdownAmplitude = breakdownAmplitude
    }

    // MARK: - Index-Based Voltage Helpers

    /// Returns the voltage at a node using a pre-resolved index, avoiding dictionary lookup.
    @inline(__always)
    private func nodeVoltage(_ idx: Int?, state: SolutionState) -> Double {
        if let idx { return state.value(at: idx) }
        return 0.0
    }

    /// Returns the diode voltage (anode - cathode) from the current state.
    @inline(__always)
    private func diodeVoltage(state: SolutionState) -> Double {
        nodeVoltage(anodeIdx, state: state) - nodeVoltage(cathodeIdx, state: state)
    }

    // MARK: - BoundDevice

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) throws {
        try requireAnalysis(.dc)
        let op = try operatingPoint(state: state)
        try stampLinearized(into: &stamper, op: op)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) throws {
        try requireAnalysis(.ac)
        guard omega.isFinite, omega >= 0 else { throw DiodeNumericalFailure.nonfiniteEvaluation }
        let op = try operatingPoint(state: state)

        let charge = try chargeEvaluation(op)
        let susceptance = omega * charge[1]
        guard susceptance.isFinite else { throw DiodeNumericalFailure.nonfiniteEvaluation }
        // Validate every product before the first external stamping callback.
        stampACValues(into: &stamper, conductance: op.gd, susceptance: susceptance)
    }

    private func stampACValues(into stamper: inout ComplexMatrixStamper, conductance: Double, susceptance: Double) {
        if let a = anodeIdx { stamper.stampMatrix(a, a, conductance, susceptance) }
        if let c = cathodeIdx { stamper.stampMatrix(c, c, conductance, susceptance) }
        if let a = anodeIdx, let c = cathodeIdx {
            stamper.stampMatrix(a, c, -conductance, -susceptance)
            stamper.stampMatrix(c, a, -conductance, -susceptance)
        }
    }

    public func beginTransientSession(initialState: SolutionState) throws {
        try requireAnalysis(.transient)
        let charge = try chargeEvaluation(operatingPoint(state: initialState))
        try history.begin(charge: charge[0])
    }

    public func endTransientSession() { history.end() }

    public func stampTransient(into stamper: inout MatrixStamper, state: SolutionState,
                               integration: IntegrationState) throws {
        try requireAnalysis(.transient)
        let op = try operatingPoint(state: state)
        guard parameters.junctionCapacitance > 0 || parameters.transitTime > 0 else {
            try stampLinearized(into: &stamper, op: op)
            return
        }
        let charge = try chargeEvaluation(op)
        let dynamic = try history.trial(charge: charge[0], capacitance: charge[1], integration: integration)
        try stampLinearized(into: &stamper, op: .init(id: op.id + dynamic[1], gd: op.gd + dynamic[0],
            vd: op.vd, forwardCurrent: op.forwardCurrent, forwardConductance: op.forwardConductance))
    }

    public func commitTransientStep(state: SolutionState, integration: IntegrationState) throws {
        try requireAnalysis(.transient)
        let charge = try chargeEvaluation(operatingPoint(state: state))
        try history.commit(charge: charge[0], capacitance: charge[1], integration: integration)
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

    public func noiseContributions(state: SolutionState, frequency: Double) throws -> [NoiseSource] {
        try requireAnalysis(.noise)
        let op = try operatingPoint(state: state)
        guard frequency.isFinite, frequency > 0 else { throw DiodeNumericalFailure.nonfiniteEvaluation }
        let q = 1.602176634e-19
        let shotNoise = 2.0 * q * abs(op.id)
        guard shotNoise.isFinite, shotNoise > 0 || op.id == 0 else { throw DiodeNumericalFailure.nonfiniteEvaluation }
        guard shotNoise > 0 else { return [] }
        return [
            NoiseSource(
                name: "\(instance.name)_shot",
                positiveNode: anode,
                negativeNode: cathode,
                currentSpectralDensity: shotNoise
            )
        ]
    }

    private func requireAnalysis(_ capability: DiodeAnalysisCapabilities) throws(DiodePreparationFailure) {
        guard preparationReceipt.identity.analyses.contains(capability) else { throw .unsupportedAnalysis }
    }

    // MARK: - Internal Model

    private struct OperatingPointResult {
        let id: Double
        let gd: Double
        let vd: Double
        let forwardCurrent: Double
        let forwardConductance: Double
    }

    private func operatingPoint(state: SolutionState) throws -> OperatingPointResult {
        let va = try anodeIdx.map { try state.checkedValue(at: $0) } ?? 0
        let vc = try cathodeIdx.map { try state.checkedValue(at: $0) } ?? 0
        let vd = va - vc
        let u = parameters.emissionCoefficient * parameters.thermalVoltage
        let argument = vd / u
        let forward = effectiveSaturationCurrent * expm1(argument)
        let forwardG = effectiveSaturationCurrent / u * exp(argument)
        var current = forward, conductance = forwardG
        if let amplitude = breakdownAmplitude, amplitude > 0 {
            let baseline = exp(-parameters.breakdownVoltage / u)
            let reverse = exp(-(vd + parameters.breakdownVoltage) / u)
            // Preserve cancellation accuracy near zero without losing deep reverse current.
            let difference = abs(argument) < 0.5 ? baseline * expm1(-argument) : reverse - baseline
            current -= amplitude * difference
            conductance += amplitude / u * reverse
        }
        guard vd.isFinite, current.isFinite, conductance.isFinite, conductance >= 0,
              forward.isFinite, forwardG.isFinite else { throw DiodeNumericalFailure.nonfiniteEvaluation }
        return .init(id: current, gd: conductance, vd: vd, forwardCurrent: forward, forwardConductance: forwardG)
    }

    /// Integral of the depletion law plus forward minority-carrier charge.
    private func chargeEvaluation(_ op: OperatingPointResult) throws(DiodeNumericalFailure) -> SIMD2<Double> {
        let cjo = parameters.junctionCapacitance, vj = parameters.junctionPotential
        let m = parameters.gradingCoefficient, a = 1 - m
        var charge = 0.0, capacitance = 0.0
        if cjo > 0 {
            let threshold = vj / 2
            if op.vd < threshold {
                let logarithm = log1p(-op.vd / vj)
                charge = -cjo * vj / a * expm1(a * logarithm)
                capacitance = cjo * exp(-m * logarithm)
            } else {
                let cf = cjo * pow(2, m), slope = 2 * m * cf / vj
                let qf = -cjo * vj / a * expm1(a * log(0.5))
                let delta = op.vd - threshold
                charge = qf + cf * delta + slope * delta * delta / 2
                capacitance = cf + slope * delta
            }
        }
        charge += parameters.transitTime * op.forwardCurrent
        capacitance += parameters.transitTime * op.forwardConductance
        guard charge.isFinite, capacitance.isFinite, capacitance >= 0 else { throw .nonfiniteEvaluation }
        return SIMD2(charge, capacitance)
    }

    // MARK: - VoltageLimitingDevice

    /// PN junctions must be limited from the first iteration to avoid an
    /// exponential blow-up when driven far from the operating point.
    public var limitsFirstIteration: Bool { true }

    public func limitVoltages(solution: inout [Double], previousSolution: [Double]) {
        let vt = parameters.emissionCoefficient * parameters.thermalVoltage
        let isat = effectiveSaturationCurrent

        let vaNew = anodeIdx.map { solution[$0] } ?? 0.0
        let vcNew = cathodeIdx.map { solution[$0] } ?? 0.0
        let vaOld = anodeIdx.map { previousSolution[$0] } ?? 0.0
        let vcOld = cathodeIdx.map { previousSolution[$0] } ?? 0.0

        let vdNew = vaNew - vcNew
        let vdOld = vaOld - vcOld

        let vdLimited: Double
        if let amplitude = breakdownAmplitude, amplitude > 0, vdNew < -parameters.breakdownVoltage {
            let shift = parameters.breakdownVoltage
            vdLimited = -shift - PNJunctionLimiter.limit(vNew: -(vdNew + shift), vOld: -(vdOld + shift),
                vt: vt, isat: amplitude)
        } else { vdLimited = PNJunctionLimiter.limit(vNew: vdNew, vOld: vdOld, vt: vt, isat: isat) }

        if vdLimited != vdNew {
            let correction = vdLimited - vdNew
            if let aIdx = anodeIdx {
                solution[aIdx] += correction
            } else if let cIdx = cathodeIdx {
                solution[cIdx] -= correction
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
    private func stampLinearized(into stamper: inout MatrixStamper, op: OperatingPointResult) throws(DiodeNumericalFailure) {
        let ieq = op.id - op.gd * op.vd
        guard op.id.isFinite, op.gd.isFinite, ieq.isFinite else { throw .nonfiniteEvaluation }
        // Conductance stamp (fast path when CSR indices available)
        if let sv = stamper.stampValue, stampAA != nil || stampCC != nil {
            if let idx = stampAA { sv(idx, op.gd) }
            if let idx = stampCC { sv(idx, op.gd) }
            if let idx = stampAC { sv(idx, -op.gd) }
            if let idx = stampCA { sv(idx, -op.gd) }
        } else {
            // Fallback to dictionary-based stamping
            let aIdx = stamper.nodeIndex(anode)
            let cIdx = stamper.nodeIndex(cathode)

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
        }

        // Equivalent current source: Ieq = Id - gd * Vd
        // Current flows from anode to cathode (use pre-resolved indices)
        if let aIdx = anodeIdx {
            stamper.stampRHS(aIdx, -ieq)
        }
        if let cIdx = cathodeIdx {
            stamper.stampRHS(cIdx, ieq)
        }
    }
}

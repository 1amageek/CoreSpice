import Foundation
import CoreSpiceIR
import CoreSpiceDevices

/// A photodiode bound to circuit nodes and an optical input node.
///
/// The electrical model is a standard PN junction (Shockley equation) with:
/// - Forward/reverse bias I-V characteristic
/// - Junction capacitance (depletion + diffusion)
/// - Voltage limiting for NR stability
///
/// The optical model adds:
/// - Photocurrent: `I_photo = R(lambda) * P_optical + I_dark`
/// - Jacobian entries from optical sensitivity propagation:
///   `gm_opto = R(lambda) * dP/dV_j` stamped for each upstream electrical variable
///
/// The `gm_opto` Jacobian entries ensure quadratic convergence of the
/// Newton-Raphson solver when the optical power depends on electrical
/// variables (e.g., laser diode drive current).
public struct BoundPhotodiode: OptoelectronicDevice, VoltageLimitingDevice, NoisyDevice, Sendable {

    public let instance: Instance
    private let anode: Node
    private let cathode: Node
    private let parameters: PhotodiodeModelParameters

    /// Pre-resolved matrix indices (nil for ground).
    private let anodeIdx: Int?
    private let cathodeIdx: Int?

    /// Optical input node from which this photodiode receives light.
    private let opticalInput: OpticalNode

    private static let maxExpArg: Double = 40.0
    private static let gmin: Double = 1e-12
    private static let voltageTolerance: Double = 1e-6

    public var opticalInputNodes: [OpticalNode] { [opticalInput] }
    public var opticalOutputNodes: [OpticalNode] { [] }

    init(
        instance: Instance,
        anode: Node,
        cathode: Node,
        anodeIdx: Int?,
        cathodeIdx: Int?,
        opticalInput: OpticalNode,
        parameters: PhotodiodeModelParameters
    ) {
        self.instance = instance
        self.anode = anode
        self.cathode = cathode
        self.anodeIdx = anodeIdx
        self.cathodeIdx = cathodeIdx
        self.opticalInput = opticalInput
        self.parameters = parameters
    }

    // MARK: - Voltage Helpers

    @inline(__always)
    private func nodeVoltage(_ idx: Int?, state: SolutionState) -> Double {
        if let idx { return state.value(at: idx) }
        return 0.0
    }

    @inline(__always)
    private func diodeVoltage(state: SolutionState) -> Double {
        nodeVoltage(anodeIdx, state: state) - nodeVoltage(cathodeIdx, state: state)
    }

    // MARK: - OptoelectronicDevice

    public func computeOpticalOutput(
        electricalState: SolutionState,
        opticalState: OpticalState
    ) -> [OpticalNode: OpticalSignal] {
        // Photodiodes are receivers; they do not emit light.
        [:]
    }

    public func stampDC(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        opticalState: OpticalState
    ) {
        // 1. Standard PN junction linearization
        let op = operatingPoint(state: state)
        stampDiodeLinearized(into: &stamper, op: op)

        // 2. Photocurrent source: I_photo = R * P + I_dark
        let opticalPower = opticalState.power(at: opticalInput)
        let iPhoto = parameters.responsivity * opticalPower + parameters.darkCurrent
        // Photocurrent flows cathode → anode (reverse current convention for PD)
        if let aIdx = stamper.nodeIndex(anode) {
            stamper.stampRHS(aIdx, -iPhoto)
        }
        if let cIdx = stamper.nodeIndex(cathode) {
            stamper.stampRHS(cIdx, iPhoto)
        }

        // 3. gm_opto Jacobian: dI_photo/dV_j = R * dP/dV_j
        //    Stamps optical-to-electrical coupling into the MNA Jacobian
        //    for each upstream electrical variable that affects the optical power.
        for (elecVarIdx, dPdV) in opticalState.sensitivities.sensitivities(for: opticalInput.id) {
            let gmOpto = parameters.responsivity * dPdV
            if let aIdx = stamper.nodeIndex(anode) {
                stamper.stampMatrix(aIdx, elecVarIdx, gmOpto)
            }
            if let cIdx = stamper.nodeIndex(cathode) {
                stamper.stampMatrix(cIdx, elecVarIdx, -gmOpto)
            }
        }
    }

    public func stampAC(
        into stamper: inout ComplexMatrixStamper,
        state: SolutionState,
        opticalState: OpticalState,
        omega: Double
    ) {
        let op = operatingPoint(state: state)

        let aIdx = stamper.nodeIndex(anode)
        let cIdx = stamper.nodeIndex(cathode)

        // Small-signal diode conductance
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

        // Junction capacitance: depletion + diffusion
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

        // AC small-signal gm_opto: same as DC (frequency-independent for PD receiver)
        for (elecVarIdx, dPdV) in opticalState.sensitivities.sensitivities(for: opticalInput.id) {
            let gmOpto = parameters.responsivity * dPdV
            if let aIdx {
                stamper.stampMatrix(aIdx, elecVarIdx, gmOpto, 0.0)
            }
            if let cIdx {
                stamper.stampMatrix(cIdx, elecVarIdx, -gmOpto, 0.0)
            }
        }
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        opticalState: OpticalState,
        integration: IntegrationState
    ) {
        // DC part (diode I-V + photocurrent + gm_opto)
        stampDC(into: &stamper, state: state, opticalState: opticalState)

        // Junction capacitance companion model
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

    public func checkConvergence(
        state: SolutionState, previousState: SolutionState,
        opticalState: OpticalState, previousOpticalState: OpticalState
    ) -> ConvergenceResult {
        // Electrical convergence: diode voltage
        let vdNew = diodeVoltage(state: state)
        let vdOld = diodeVoltage(state: previousState)
        let delta = abs(vdNew - vdOld)

        if delta >= Self.voltageTolerance {
            return .notConverged(maxDelta: delta, deviceName: instance.name)
        }

        // Optical convergence: optical power change
        let pNew = opticalState.power(at: opticalInput)
        let pOld = previousOpticalState.power(at: opticalInput)
        let optDelta = abs(pNew - pOld)
        if optDelta > 1e-3 * abs(pNew) + 1e-9 {
            return .notConverged(maxDelta: optDelta, deviceName: instance.name)
        }

        return .converged
    }

    // MARK: - NoisyDevice

    public func noiseContributions(state: SolutionState, frequency: Double) -> [NoiseSource] {
        noiseContributions(state: state, opticalState: OpticalState(), frequency: frequency)
    }

    public func noiseContributions(
        state: SolutionState,
        opticalState: OpticalState,
        frequency: Double
    ) -> [NoiseSource] {
        let q = 1.602176634e-19

        // Shot noise: S_shot = 2q * (I_photo + I_dark)
        let opticalPower = opticalState.power(at: opticalInput)
        let iPhoto = parameters.responsivity * opticalPower + parameters.darkCurrent
        let shotNoise = 2.0 * q * abs(iPhoto)

        return [
            NoiseSource(
                name: "\(instance.name)_shot",
                positiveNode: anode,
                negativeNode: cathode,
                currentSpectralDensity: shotNoise
            )
        ]
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

    // MARK: - BoundDevice (delegated to optical-aware versions)

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        stampDC(into: &stamper, state: state, opticalState: OpticalState())
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        stampAC(into: &stamper, state: state, opticalState: OpticalState(), omega: omega)
    }

    public func stampTransient(into stamper: inout MatrixStamper, state: SolutionState, integration: IntegrationState) {
        stampTransient(into: &stamper, state: state, opticalState: OpticalState(), integration: integration)
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        checkConvergence(state: state, previousState: previousState,
                        opticalState: OpticalState(), previousOpticalState: OpticalState())
    }

    // MARK: - Internal Diode Model

    private struct OperatingPointResult {
        let id: Double
        let gd: Double
        let vd: Double
    }

    private func operatingPoint(state: SolutionState) -> OperatingPointResult {
        let vd = diodeVoltage(state: state)
        let vt = parameters.thermalVoltage
        let n = parameters.emissionCoefficient
        let isat = parameters.saturationCurrent
        let nvt = n * vt

        let id: Double
        let gd: Double

        if vd >= -5 * nvt {
            let expArg = min(vd / nvt, Self.maxExpArg)
            let expVal = exp(expArg)
            id = isat * (expVal - 1.0)
            gd = isat / nvt * expVal + Self.gmin
        } else if vd >= -parameters.breakdownVoltage {
            id = -isat
            gd = isat / nvt + Self.gmin
        } else {
            let vbr = parameters.breakdownVoltage
            let ibv = parameters.breakdownCurrent
            let vBreak = vd + vbr
            let breakdownExp = exp((-vBreak - vbr) / nvt)
            id = -isat - ibv * breakdownExp
            gd = ibv / nvt * breakdownExp + Self.gmin
        }

        return OperatingPointResult(id: id, gd: gd, vd: vd)
    }

    private func stampDiodeLinearized(into stamper: inout MatrixStamper, op: OperatingPointResult) {
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

        let ieq = op.id - op.gd * op.vd
        if let aIdx {
            stamper.stampRHS(aIdx, -ieq)
        }
        if let cIdx {
            stamper.stampRHS(cIdx, ieq)
        }
    }

    private func junctionCapacitance(vd: Double) -> Double {
        let cjo = parameters.junctionCapacitance
        if cjo == 0 { return 0 }

        let vj = parameters.junctionPotential
        let m = parameters.gradingCoefficient

        if vd < 0.5 * vj {
            return cjo / pow(1.0 - vd / vj, m)
        } else {
            let c_half = cjo / pow(0.5, m)
            let slope = c_half * m / (vj * 0.5)
            return c_half + slope * (vd - 0.5 * vj)
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

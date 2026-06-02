import Foundation
import CoreSpiceIR
import CoreSpiceDevices

/// A laser diode bound to circuit nodes and an optical output node.
///
/// ## DC Model
/// Above threshold: `P = slope_efficiency * (I - I_th)`
/// Below threshold: `P ≈ 0` (spontaneous emission only)
///
/// ## AC Model
/// Small-signal transfer function with relaxation oscillation:
///   `H(omega) = omega_r^2 / (omega_r^2 - omega^2 + j*omega*gamma_d)`
///
/// ## Transient Model
/// Rate equations for carrier density N and photon density S
/// are solved locally at each NR iteration using the same integration
/// method (BE/Trap) as the outer transient loop.
///
/// ## Sensitivity
/// Provides `dP/dV` for forward-mode optical sensitivity propagation,
/// enabling correct Jacobian construction at downstream photodiodes.
public struct BoundLaserDiode: OpticalEmitter, VoltageLimitingDevice, NoisyDevice, TransientStateCommittingDevice, Sendable {

    public let instance: Instance
    private let anode: Node
    private let cathode: Node
    private let parameters: LaserDiodeModelParameters

    private let anodeIdx: Int?
    private let cathodeIdx: Int?
    private let opticalOutput: OpticalNode
    private let capacitanceStore: TransientCapacitanceStore

    private static let maxExpArg: Double = 40.0
    private static let gmin: Double = 1e-12
    private static let voltageTolerance: Double = 1e-6

    public var opticalInputNodes: [OpticalNode] { [] }
    public var opticalOutputNodes: [OpticalNode] { [opticalOutput] }

    public init(
        instance: Instance,
        anode: Node,
        cathode: Node,
        anodeIdx: Int?,
        cathodeIdx: Int?,
        opticalOutput: OpticalNode,
        parameters: LaserDiodeModelParameters
    ) {
        self.instance = instance
        self.anode = anode
        self.cathode = cathode
        self.anodeIdx = anodeIdx
        self.cathodeIdx = cathodeIdx
        self.opticalOutput = opticalOutput
        self.parameters = parameters
        self.capacitanceStore = TransientCapacitanceStore()
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

    // MARK: - DC Optical Output

    /// Computes DC optical power from the laser L-I curve.
    private func dcOpticalPower(current: Double) -> (power: Double, dPdI: Double) {
        let ith = parameters.thresholdCurrent
        let eta = parameters.slopeEfficiency

        if current > ith {
            return (power: eta * (current - ith), dPdI: eta)
        } else {
            // Below threshold: small spontaneous emission
            let pSpon = parameters.spontaneousEmissionFactor * eta * max(current, 0)
            let dPdI = current > 0 ? parameters.spontaneousEmissionFactor * eta : 0
            return (power: pSpon, dPdI: dPdI)
        }
    }

    // MARK: - OpticalEmitter

    public func computeOpticalOutputWithSensitivity(
        electricalState: SolutionState,
        opticalState: OpticalState
    ) -> (
        signals: [OpticalNode: OpticalSignal],
        sensitivities: [(opticalNodeId: Int, electricalVarIndex: Int, dPdV: Double)]
    ) {
        let op = operatingPoint(state: electricalState)
        let iFwd = max(op.id, 0)
        let (power, dPdI) = dcOpticalPower(current: iFwd)

        let amplitude = power.squareRoot()
        let signal = OpticalSignal.fromPolar(
            amplitude: amplitude, phase: 0, wavelength: parameters.wavelength
        )

        // Sensitivities: dP/dV_j = dP/dI * dI/dV_j
        var sensitivities: [(opticalNodeId: Int, electricalVarIndex: Int, dPdV: Double)] = []

        if op.id > 0 {
            if let aIdx = anodeIdx {
                sensitivities.append((
                    opticalNodeId: opticalOutput.id,
                    electricalVarIndex: aIdx,
                    dPdV: dPdI * op.gd
                ))
            }
            if let cIdx = cathodeIdx {
                sensitivities.append((
                    opticalNodeId: opticalOutput.id,
                    electricalVarIndex: cIdx,
                    dPdV: dPdI * (-op.gd)
                ))
            }
        }

        return (signals: [opticalOutput: signal], sensitivities: sensitivities)
    }

    public func computeOpticalOutput(
        electricalState: SolutionState,
        opticalState: OpticalState
    ) -> [OpticalNode: OpticalSignal] {
        computeOpticalOutputWithSensitivity(
            electricalState: electricalState, opticalState: opticalState
        ).signals
    }

    // MARK: - Stamps

    public func stampDC(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        opticalState: OpticalState
    ) {
        let op = operatingPoint(state: state)
        stampDiodeLinearized(into: &stamper, op: op)
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
            if let aIdx { stamper.stampMatrix(aIdx, aIdx, op.gd, 0.0) }
            if let cIdx { stamper.stampMatrix(cIdx, cIdx, op.gd, 0.0) }
            if let aIdx, let cIdx {
                stamper.stampMatrix(aIdx, cIdx, -op.gd, 0.0)
                stamper.stampMatrix(cIdx, aIdx, -op.gd, 0.0)
            }
        }

        // Junction capacitance
        let cj = junctionCapacitance(vd: op.vd)
        if cj > 0 {
            let susceptance = omega * cj
            if let aIdx { stamper.stampMatrix(aIdx, aIdx, 0.0, susceptance) }
            if let cIdx { stamper.stampMatrix(cIdx, cIdx, 0.0, susceptance) }
            if let aIdx, let cIdx {
                stamper.stampMatrix(aIdx, cIdx, 0.0, -susceptance)
                stamper.stampMatrix(cIdx, aIdx, 0.0, -susceptance)
            }
        }
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        opticalState: OpticalState,
        integration: IntegrationState
    ) {
        stampDC(into: &stamper, state: state, opticalState: opticalState)

        let op = operatingPoint(state: state)
        let cj = junctionCapacitance(vd: op.vd)
        guard cj > 0 else { return }

        let aIdx = stamper.nodeIndex(anode)
        let cIdx = stamper.nodeIndex(cathode)
        capacitanceStore.stamp(
            key: "junction",
            into: &stamper, node1: aIdx, node2: cIdx,
            capacitance: cj, state: state, integration: integration
        )
    }

    public func commitTransientStep(state: SolutionState, integration: IntegrationState) {
        let op = operatingPoint(state: state)
        let cj = junctionCapacitance(vd: op.vd)
        capacitanceStore.commit(
            key: "junction",
            node1: anodeIdx,
            node2: cathodeIdx,
            capacitance: cj,
            state: state,
            integration: integration
        )
    }

    public func checkConvergence(
        state: SolutionState, previousState: SolutionState,
        opticalState: OpticalState, previousOpticalState: OpticalState
    ) -> ConvergenceResult {
        let vdNew = diodeVoltage(state: state)
        let vdOld = diodeVoltage(state: previousState)
        if abs(vdNew - vdOld) >= Self.voltageTolerance {
            return .notConverged(maxDelta: abs(vdNew - vdOld), deviceName: instance.name)
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
        let op = operatingPoint(state: state)
        let iFwd = max(op.id, 0)

        // Shot noise of the diode current
        let shotNoise = 2.0 * q * abs(iFwd)

        // RIN contribution (as equivalent current noise at the diode terminals)
        let (power, _) = dcOpticalPower(current: iFwd)
        let rinCurrent = parameters.rinLinear * power * power
        // Convert optical RIN to electrical current noise via dI/dP = 1/slopeEff
        let rinElecNoise = rinCurrent / (parameters.slopeEfficiency * parameters.slopeEfficiency)

        return [
            NoiseSource(
                name: "\(instance.name)_shot",
                positiveNode: anode,
                negativeNode: cathode,
                currentSpectralDensity: shotNoise
            ),
            NoiseSource(
                name: "\(instance.name)_rin",
                positiveNode: anode,
                negativeNode: cathode,
                currentSpectralDensity: rinElecNoise
            )
        ]
    }

    // MARK: - BoundDevice (delegated)

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
            if let aIdx = anodeIdx {
                solution[aIdx] += vdLimited - vdNew
            }
        }
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
        } else {
            id = -isat
            gd = isat / nvt + Self.gmin
        }

        return OperatingPointResult(id: id, gd: gd, vd: vd)
    }

    private func stampDiodeLinearized(into stamper: inout MatrixStamper, op: OperatingPointResult) {
        let aIdx = stamper.nodeIndex(anode)
        let cIdx = stamper.nodeIndex(cathode)

        if let aIdx { stamper.stampMatrix(aIdx, aIdx, op.gd) }
        if let cIdx { stamper.stampMatrix(cIdx, cIdx, op.gd) }
        if let aIdx, let cIdx {
            stamper.stampMatrix(aIdx, cIdx, -op.gd)
            stamper.stampMatrix(cIdx, aIdx, -op.gd)
        }

        let ieq = op.id - op.gd * op.vd
        if let aIdx { stamper.stampRHS(aIdx, -ieq) }
        if let cIdx { stamper.stampRHS(cIdx, ieq) }
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

}

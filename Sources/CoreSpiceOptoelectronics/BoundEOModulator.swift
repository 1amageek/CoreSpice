import Foundation
import CoreSpiceIR
import CoreSpiceDevices

/// A Mach-Zehnder electro-optic modulator (MZM) bound to circuit nodes.
///
/// ## Ports
/// - Electrical: signal_pos, signal_neg (RF drive), bias_pos, bias_neg (DC bias)
/// - Optical: optical_in, optical_out
///
/// ## Transfer Function
/// ```
/// P_out = P_in * IL * cos²(π * (V_bias + V_signal) / (2 * Vπ) + φ₀)
/// ```
/// where `IL` is insertion loss, `Vπ` is half-wave voltage.
///
/// ## Electrical Model
/// Electrode modeled as a series R-C between signal_pos and signal_neg.
/// Bias port is high-impedance (voltage probe only).
///
/// ## Sensitivity Propagation
/// Two types of sensitivities are provided:
/// 1. **Upstream**: `dP_out/dV_j = T(V) × dP_in/dV_j` (chain rule from optical input)
/// 2. **Local**: `dP_out/dV_elec = P_in × dT/dV` where
///    `dT/dV = -IL × sin(2×arg) × π/(2×Vπ)`
public struct BoundEOModulator: OpticalEmitter, Sendable {

    public let instance: Instance

    private let signalPos: Node
    private let signalNeg: Node
    private let biasPos: Node
    private let biasNeg: Node

    private let signalPosIdx: Int?
    private let signalNegIdx: Int?
    private let biasPosIdx: Int?
    private let biasNegIdx: Int?

    private let opticalInput: OpticalNode
    private let opticalOutput: OpticalNode

    private let parameters: EOModulatorModelParameters

    private static let voltageTolerance: Double = 1e-6

    public var opticalInputNodes: [OpticalNode] { [opticalInput] }
    public var opticalOutputNodes: [OpticalNode] { [opticalOutput] }

    public init(
        instance: Instance,
        signalPos: Node,
        signalNeg: Node,
        biasPos: Node,
        biasNeg: Node,
        signalPosIdx: Int?,
        signalNegIdx: Int?,
        biasPosIdx: Int?,
        biasNegIdx: Int?,
        opticalInput: OpticalNode,
        opticalOutput: OpticalNode,
        parameters: EOModulatorModelParameters
    ) {
        self.instance = instance
        self.signalPos = signalPos
        self.signalNeg = signalNeg
        self.biasPos = biasPos
        self.biasNeg = biasNeg
        self.signalPosIdx = signalPosIdx
        self.signalNegIdx = signalNegIdx
        self.biasPosIdx = biasPosIdx
        self.biasNegIdx = biasNegIdx
        self.opticalInput = opticalInput
        self.opticalOutput = opticalOutput
        self.parameters = parameters
    }

    // MARK: - Voltage Helpers

    @inline(__always)
    private func nodeVoltage(_ idx: Int?, state: SolutionState) -> Double {
        if let idx { return state.value(at: idx) }
        return 0.0
    }

    @inline(__always)
    private func signalVoltage(state: SolutionState) -> Double {
        nodeVoltage(signalPosIdx, state: state) - nodeVoltage(signalNegIdx, state: state)
    }

    @inline(__always)
    private func biasVoltage(state: SolutionState) -> Double {
        nodeVoltage(biasPosIdx, state: state) - nodeVoltage(biasNegIdx, state: state)
    }

    // MARK: - MZM Transfer Function

    /// Computes the MZM operating point from electrical state.
    private func mzmOperatingPoint(state: SolutionState) -> MZMOperatingPoint {
        let vSig = signalVoltage(state: state)
        let vBias = biasVoltage(state: state)
        let vTotal = vSig + vBias

        let arg = .pi * vTotal / (2.0 * parameters.vPi) + parameters.biasPhase
        let cosArg = cos(arg)
        let il = parameters.insertionLoss

        // Power transfer: T = IL * cos²(arg)
        let tPower = il * cosArg * cosArg

        // Field transfer: sqrt(IL) * cos(arg)
        let tField = il.squareRoot() * cosArg

        // dT_power/dV_total = -IL * sin(2*arg) * π / (2*Vπ)
        let dTdV = -il * sin(2.0 * arg) * .pi / (2.0 * parameters.vPi)

        return MZMOperatingPoint(
            vSignal: vSig, vBias: vBias,
            tPower: tPower, tField: tField, dTdV: dTdV
        )
    }

    private struct MZMOperatingPoint {
        let vSignal: Double
        let vBias: Double
        let tPower: Double
        let tField: Double
        let dTdV: Double
    }

    // MARK: - OpticalEmitter

    public func computeOpticalOutputWithSensitivity(
        electricalState: SolutionState,
        opticalState: OpticalState
    ) -> (
        signals: [OpticalNode: OpticalSignal],
        sensitivities: [(opticalNodeId: Int, electricalVarIndex: Int, dPdV: Double)]
    ) {
        let op = mzmOperatingPoint(state: electricalState)
        let inputSignal = opticalState.signal(at: opticalInput)
        let pIn = inputSignal.power

        // Output field: preserve input phase, scale by field transfer
        let outRe = op.tField * inputSignal.re
        let outIm = op.tField * inputSignal.im
        let outputSignal = OpticalSignal(
            re: outRe, im: outIm,
            wavelength: inputSignal.wavelength > 0 ? inputSignal.wavelength : 1550e-9
        )

        var sensitivities: [(opticalNodeId: Int, electricalVarIndex: Int, dPdV: Double)] = []

        // 1. Upstream sensitivities: dP_out/dV_j = T_power * dP_in/dV_j
        for (elecVarIdx, dPdV) in opticalState.sensitivities.sensitivities(for: opticalInput.id) {
            let propagated = op.tPower * dPdV
            if abs(propagated) > 1e-30 {
                sensitivities.append((
                    opticalNodeId: opticalOutput.id,
                    electricalVarIndex: elecVarIdx,
                    dPdV: propagated
                ))
            }
        }

        // 2. Local sensitivities: dP_out/dV_elec = P_in * dT/dV
        let localSens = pIn * op.dTdV

        if abs(localSens) > 1e-30 {
            if let spIdx = signalPosIdx {
                sensitivities.append((
                    opticalNodeId: opticalOutput.id,
                    electricalVarIndex: spIdx,
                    dPdV: localSens
                ))
            }
            if let snIdx = signalNegIdx {
                sensitivities.append((
                    opticalNodeId: opticalOutput.id,
                    electricalVarIndex: snIdx,
                    dPdV: -localSens
                ))
            }
            if let bpIdx = biasPosIdx {
                sensitivities.append((
                    opticalNodeId: opticalOutput.id,
                    electricalVarIndex: bpIdx,
                    dPdV: localSens
                ))
            }
            if let bnIdx = biasNegIdx {
                sensitivities.append((
                    opticalNodeId: opticalOutput.id,
                    electricalVarIndex: bnIdx,
                    dPdV: -localSens
                ))
            }
        }

        return (signals: [opticalOutput: outputSignal], sensitivities: sensitivities)
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
        // Electrode resistance between signal_pos and signal_neg
        let gElec = 1.0 / parameters.electrodeResistance
        let spIdx = stamper.nodeIndex(signalPos)
        let snIdx = stamper.nodeIndex(signalNeg)

        if let sp = spIdx { stamper.stampMatrix(sp, sp, gElec) }
        if let sn = snIdx { stamper.stampMatrix(sn, sn, gElec) }
        if let sp = spIdx, let sn = snIdx {
            stamper.stampMatrix(sp, sn, -gElec)
            stamper.stampMatrix(sn, sp, -gElec)
        }
    }

    public func stampAC(
        into stamper: inout ComplexMatrixStamper,
        state: SolutionState,
        opticalState: OpticalState,
        omega: Double
    ) {
        let spIdx = stamper.nodeIndex(signalPos)
        let snIdx = stamper.nodeIndex(signalNeg)

        // Electrode resistance
        let gElec = 1.0 / parameters.electrodeResistance

        if let sp = spIdx { stamper.stampMatrix(sp, sp, gElec, 0.0) }
        if let sn = snIdx { stamper.stampMatrix(sn, sn, gElec, 0.0) }
        if let sp = spIdx, let sn = snIdx {
            stamper.stampMatrix(sp, sn, -gElec, 0.0)
            stamper.stampMatrix(sn, sp, -gElec, 0.0)
        }

        // Electrode capacitance
        let cElec = parameters.electrodeCapacitance
        if cElec > 0 {
            let susceptance = omega * cElec
            if let sp = spIdx { stamper.stampMatrix(sp, sp, 0.0, susceptance) }
            if let sn = snIdx { stamper.stampMatrix(sn, sn, 0.0, susceptance) }
            if let sp = spIdx, let sn = snIdx {
                stamper.stampMatrix(sp, sn, 0.0, -susceptance)
                stamper.stampMatrix(sn, sp, 0.0, -susceptance)
            }
        }
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        opticalState: OpticalState,
        integration: IntegrationState
    ) {
        // DC: electrode resistance
        stampDC(into: &stamper, state: state, opticalState: opticalState)

        // Electrode capacitance companion model
        let cElec = parameters.electrodeCapacitance
        guard cElec > 0 else { return }

        let spIdx = stamper.nodeIndex(signalPos)
        let snIdx = stamper.nodeIndex(signalNeg)
        stampTransientCapacitance(
            into: &stamper, node1: spIdx, node2: snIdx,
            cap: cElec, state: state, integration: integration
        )
    }

    public func checkConvergence(
        state: SolutionState, previousState: SolutionState,
        opticalState: OpticalState, previousOpticalState: OpticalState
    ) -> ConvergenceResult {
        // Electrical: signal voltage
        let vSigNew = signalVoltage(state: state)
        let vSigOld = signalVoltage(state: previousState)
        let sigDelta = abs(vSigNew - vSigOld)
        if sigDelta >= Self.voltageTolerance {
            return .notConverged(maxDelta: sigDelta, deviceName: instance.name)
        }

        // Electrical: bias voltage
        let vBiasNew = biasVoltage(state: state)
        let vBiasOld = biasVoltage(state: previousState)
        let biasDelta = abs(vBiasNew - vBiasOld)
        if biasDelta >= Self.voltageTolerance {
            return .notConverged(maxDelta: biasDelta, deviceName: instance.name)
        }

        // Optical: output power
        let pNew = opticalState.power(at: opticalOutput)
        let pOld = previousOpticalState.power(at: opticalOutput)
        let optDelta = abs(pNew - pOld)
        if optDelta > 1e-3 * abs(pNew) + 1e-9 {
            return .notConverged(maxDelta: optDelta, deviceName: instance.name)
        }

        return .converged
    }

    public func noiseContributions(
        state: SolutionState,
        opticalState: OpticalState,
        frequency: Double
    ) -> [NoiseSource] {
        // Electrode thermal noise: S = 4kT/R
        let k = 1.380649e-23
        let t = 300.15
        let thermalNoise = 4.0 * k * t / parameters.electrodeResistance

        return [
            NoiseSource(
                name: "\(instance.name)_thermal",
                positiveNode: signalPos,
                negativeNode: signalNeg,
                currentSpectralDensity: thermalNoise
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

    // MARK: - Transient Capacitance Helper

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

        if let n1 = node1 { stamper.stampMatrix(n1, n1, geq) }
        if let n2 = node2 { stamper.stampMatrix(n2, n2, geq) }
        if let n1 = node1, let n2 = node2 {
            stamper.stampMatrix(n1, n2, -geq)
            stamper.stampMatrix(n2, n1, -geq)
        }
        if let n1 = node1 { stamper.stampRHS(n1, ieq) }
        if let n2 = node2 { stamper.stampRHS(n2, -ieq) }
    }
}

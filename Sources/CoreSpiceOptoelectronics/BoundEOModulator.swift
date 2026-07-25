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
public struct BoundEOModulator: OpticalEmitter, TransientStateCommittingDevice, Sendable {

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
    private let capacitanceStore: TransientCapacitanceStore

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
        self.capacitanceStore = TransientCapacitanceStore()
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
        sensitivities: [(opticalNodeID: Int, electricalVarIndex: Int, dPdV: Double)]
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

        var sensitivities: [(opticalNodeID: Int, electricalVarIndex: Int, dPdV: Double)] = []

        // 1. Upstream sensitivities: dP_out/dV_j = T_power * dP_in/dV_j
        for (elecVarIdx, dPdV) in opticalState.sensitivities.sensitivities(for: opticalInput.id) {
            let propagated = op.tPower * dPdV
            if abs(propagated) > 1e-30 {
                sensitivities.append((
                    opticalNodeID: opticalOutput.id,
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
                    opticalNodeID: opticalOutput.id,
                    electricalVarIndex: spIdx,
                    dPdV: localSens
                ))
            }
            if let snIdx = signalNegIdx {
                sensitivities.append((
                    opticalNodeID: opticalOutput.id,
                    electricalVarIndex: snIdx,
                    dPdV: -localSens
                ))
            }
            if let bpIdx = biasPosIdx {
                sensitivities.append((
                    opticalNodeID: opticalOutput.id,
                    electricalVarIndex: bpIdx,
                    dPdV: localSens
                ))
            }
            if let bnIdx = biasNegIdx {
                sensitivities.append((
                    opticalNodeID: opticalOutput.id,
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
        capacitanceStore.stamp(
            key: "electrode",
            into: &stamper, node1: spIdx, node2: snIdx,
            capacitance: cElec, state: state, integration: integration
        )
    }

    public func commitTransientStep(state: SolutionState, integration: IntegrationState) {
        capacitanceStore.commit(
            key: "electrode",
            node1: signalPosIdx,
            node2: signalNegIdx,
            capacitance: parameters.electrodeCapacitance,
            state: state,
            integration: integration
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

}

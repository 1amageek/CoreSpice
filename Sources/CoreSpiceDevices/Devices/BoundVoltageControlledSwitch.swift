import Foundation
import CoreSpiceIR

/// A voltage-controlled switch with a narrow numerical transition at its threshold.
public struct BoundVoltageControlledSwitch: BoundDevice, AcceptedStateCommittingDevice, TransientStateCommittingDevice, Sendable {

    public let instance: Instance
    private let posNode: Node
    private let negNode: Node
    private let controlPosNode: Node
    private let controlNegNode: Node
    private let onResistance: Double
    private let offResistance: Double
    private let threshold: Double
    private let hysteresis: Double
    private let hysteresisState: SwitchHysteresisState

    init(
        instance: Instance,
        posNode: Node,
        negNode: Node,
        controlPosNode: Node,
        controlNegNode: Node,
        onResistance: Double,
        offResistance: Double,
        threshold: Double,
        hysteresis: Double
    ) {
        self.instance = instance
        self.posNode = posNode
        self.negNode = negNode
        self.controlPosNode = controlPosNode
        self.controlNegNode = controlNegNode
        self.onResistance = onResistance
        self.offResistance = offResistance
        self.threshold = threshold
        self.hysteresis = hysteresis
        self.hysteresisState = SwitchHysteresisState()
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        let point = operatingPoint(state: state)
        stamper.stampConductance(
            node1: posNode,
            node2: negNode,
            conductance: point.conductance
        )
        stampControlSensitivity(into: &stamper, point: point)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        let point = operatingPoint(state: state)
        stamper.stampAdmittance(
            node1: posNode,
            node2: negNode,
            real: point.conductance,
            imag: 0.0
        )
        stampControlSensitivity(into: &stamper, point: point)
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        stampDC(into: &stamper, state: state)
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        let currentConductance = operatingPoint(state: state).conductance
        let previousConductance = operatingPoint(state: previousState).conductance
        let delta = abs(currentConductance - previousConductance)
        let tolerance = max(1.0e-12, 1.0e-3 * max(abs(currentConductance), abs(previousConductance)))
        guard delta <= tolerance else {
            return .notConverged(maxDelta: delta, deviceName: instance.name)
        }
        return .converged
    }

    public func commitAcceptedState(_ state: SolutionState) {
        guard hysteresis > 0 else { return }
        hysteresisState.commit(
            control: controlVoltage(in: state),
            threshold: threshold,
            hysteresis: hysteresis
        )
    }

    public func commitTransientStep(state: SolutionState, integration: IntegrationState) {
        commitAcceptedState(state)
    }

    private func operatingPoint(state: SolutionState) -> OperatingPoint {
        let controlVoltage = controlVoltage(in: state)
        let switchVoltage = state.voltage(at: posNode) - state.voltage(at: negNode)
        let switchPosition = switchPositionAndDerivative(controlVoltage: controlVoltage)
        let onConductance = 1.0 / onResistance
        let offConductance = 1.0 / offResistance
        let deltaConductance = onConductance - offConductance
        return OperatingPoint(
            conductance: offConductance + deltaConductance * switchPosition.position,
            controlGain: deltaConductance * switchPosition.derivative * switchVoltage,
            controlVoltage: controlVoltage
        )
    }

    private func controlVoltage(in state: SolutionState) -> Double {
        state.voltage(at: controlPosNode) - state.voltage(at: controlNegNode)
    }

    private func stampControlSensitivity(into stamper: inout MatrixStamper, point: OperatingPoint) {
        guard point.controlGain != 0 else { return }

        let posIdx = stamper.nodeIndex(posNode)
        let negIdx = stamper.nodeIndex(negNode)
        let controlPosIdx = stamper.nodeIndex(controlPosNode)
        let controlNegIdx = stamper.nodeIndex(controlNegNode)

        if let posIdx, let controlPosIdx {
            stamper.stampMatrix(posIdx, controlPosIdx, point.controlGain)
        }
        if let posIdx, let controlNegIdx {
            stamper.stampMatrix(posIdx, controlNegIdx, -point.controlGain)
        }
        if let negIdx, let controlPosIdx {
            stamper.stampMatrix(negIdx, controlPosIdx, -point.controlGain)
        }
        if let negIdx, let controlNegIdx {
            stamper.stampMatrix(negIdx, controlNegIdx, point.controlGain)
        }

        let equivalentCurrent = -point.controlGain * point.controlVoltage
        if let posIdx {
            stamper.stampRHS(posIdx, -equivalentCurrent)
        }
        if let negIdx {
            stamper.stampRHS(negIdx, equivalentCurrent)
        }
    }

    private func stampControlSensitivity(into stamper: inout ComplexMatrixStamper, point: OperatingPoint) {
        guard point.controlGain != 0 else { return }

        let posIdx = stamper.nodeIndex(posNode)
        let negIdx = stamper.nodeIndex(negNode)
        let controlPosIdx = stamper.nodeIndex(controlPosNode)
        let controlNegIdx = stamper.nodeIndex(controlNegNode)

        if let posIdx, let controlPosIdx {
            stamper.stampMatrix(posIdx, controlPosIdx, point.controlGain, 0.0)
        }
        if let posIdx, let controlNegIdx {
            stamper.stampMatrix(posIdx, controlNegIdx, -point.controlGain, 0.0)
        }
        if let negIdx, let controlPosIdx {
            stamper.stampMatrix(negIdx, controlPosIdx, -point.controlGain, 0.0)
        }
        if let negIdx, let controlNegIdx {
            stamper.stampMatrix(negIdx, controlNegIdx, point.controlGain, 0.0)
        }
    }

    private func switchPositionAndDerivative(controlVoltage: Double) -> (position: Double, derivative: Double) {
        if hysteresis > 0 {
            return (
                hysteresisState.position(
                    for: controlVoltage,
                    threshold: threshold,
                    hysteresis: hysteresis
                ),
                0.0
            )
        }
        let transitionWidth = 1.0e-3
        let normalized = clamp((controlVoltage - threshold) / transitionWidth, lower: -80.0, upper: 80.0)
        let position = 1.0 / (1.0 + exp(-normalized))
        return (position, position * (1.0 - position) / transitionWidth)
    }

    private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private struct OperatingPoint {
        let conductance: Double
        let controlGain: Double
        let controlVoltage: Double
    }
}

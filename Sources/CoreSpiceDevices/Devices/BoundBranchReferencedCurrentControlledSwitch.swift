import Foundation
import CoreSpiceIR

/// A smooth current-controlled switch driven by an existing branch current.
public struct BoundBranchReferencedCurrentControlledSwitch: BoundDevice, AcceptedStateCommittingDevice, TransientStateCommittingDevice, Sendable {

    public let instance: Instance
    private let posNode: Node
    private let negNode: Node
    private let onResistance: Double
    private let offResistance: Double
    private let thresholdCurrent: Double
    private let hysteresisCurrent: Double
    private let controlBranch: Branch
    private let hysteresisState: SwitchHysteresisState

    init(
        instance: Instance,
        posNode: Node,
        negNode: Node,
        onResistance: Double,
        offResistance: Double,
        thresholdCurrent: Double,
        hysteresisCurrent: Double,
        controlBranch: Branch
    ) {
        self.instance = instance
        self.posNode = posNode
        self.negNode = negNode
        self.onResistance = onResistance
        self.offResistance = offResistance
        self.thresholdCurrent = thresholdCurrent
        self.hysteresisCurrent = hysteresisCurrent
        self.controlBranch = controlBranch
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
        guard hysteresisCurrent > 0 else { return }
        hysteresisState.commit(
            control: state.current(through: controlBranch),
            threshold: thresholdCurrent,
            hysteresis: hysteresisCurrent
        )
    }

    public func commitTransientStep(state: SolutionState, integration: IntegrationState) {
        commitAcceptedState(state)
    }

    private func operatingPoint(state: SolutionState) -> OperatingPoint {
        let controlCurrent = state.current(through: controlBranch)
        let switchVoltage = state.voltage(at: posNode) - state.voltage(at: negNode)
        let switchPosition = switchPositionAndDerivative(controlCurrent: controlCurrent)
        let onConductance = 1.0 / onResistance
        let offConductance = 1.0 / offResistance
        let deltaConductance = onConductance - offConductance
        return OperatingPoint(
            conductance: offConductance + deltaConductance * switchPosition.position,
            controlGain: deltaConductance * switchPosition.derivative * switchVoltage,
            controlCurrent: controlCurrent
        )
    }

    private func stampControlSensitivity(into stamper: inout MatrixStamper, point: OperatingPoint) {
        guard point.controlGain != 0 else { return }
        guard let controlIdx = stamper.branchIndex(controlBranch) else { return }

        let posIdx = stamper.nodeIndex(posNode)
        let negIdx = stamper.nodeIndex(negNode)

        if let posIdx {
            stamper.stampMatrix(posIdx, controlIdx, point.controlGain)
        }
        if let negIdx {
            stamper.stampMatrix(negIdx, controlIdx, -point.controlGain)
        }

        let equivalentCurrent = -point.controlGain * point.controlCurrent
        if let posIdx {
            stamper.stampRHS(posIdx, -equivalentCurrent)
        }
        if let negIdx {
            stamper.stampRHS(negIdx, equivalentCurrent)
        }
    }

    private func stampControlSensitivity(into stamper: inout ComplexMatrixStamper, point: OperatingPoint) {
        guard point.controlGain != 0 else { return }
        guard let controlIdx = stamper.branchIndex(controlBranch) else { return }

        let posIdx = stamper.nodeIndex(posNode)
        let negIdx = stamper.nodeIndex(negNode)

        if let posIdx {
            stamper.stampMatrix(posIdx, controlIdx, point.controlGain, 0.0)
        }
        if let negIdx {
            stamper.stampMatrix(negIdx, controlIdx, -point.controlGain, 0.0)
        }
    }

    private func switchPositionAndDerivative(controlCurrent: Double) -> (position: Double, derivative: Double) {
        if hysteresisCurrent > 0 {
            return (
                hysteresisState.position(
                    for: controlCurrent,
                    threshold: thresholdCurrent,
                    hysteresis: hysteresisCurrent
                ),
                0.0
            )
        }
        let transitionWidth = CurrentControlledSwitchTransition.width(
            hysteresisCurrent: hysteresisCurrent,
            thresholdCurrent: thresholdCurrent,
            controlCurrent: controlCurrent
        )
        let normalized = clamp((controlCurrent - thresholdCurrent) / transitionWidth, lower: -80.0, upper: 80.0)
        let position = 1.0 / (1.0 + exp(-normalized))
        return (position, position * (1.0 - position) / transitionWidth)
    }

    private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private struct OperatingPoint {
        let conductance: Double
        let controlGain: Double
        let controlCurrent: Double
    }
}

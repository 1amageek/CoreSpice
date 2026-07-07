import Foundation
import CoreSpiceIR

/// A smooth current-controlled switch bound to circuit nodes.
public struct BoundCurrentControlledSwitch: BoundDevice, Sendable {

    public let instance: Instance
    private let posNode: Node
    private let negNode: Node
    private let sensePosNode: Node
    private let senseNegNode: Node
    private let onResistance: Double
    private let offResistance: Double
    private let thresholdCurrent: Double
    private let hysteresisCurrent: Double
    private let senseBranch: Branch

    init(
        instance: Instance,
        posNode: Node,
        negNode: Node,
        sensePosNode: Node,
        senseNegNode: Node,
        onResistance: Double,
        offResistance: Double,
        thresholdCurrent: Double,
        hysteresisCurrent: Double,
        senseBranch: Branch
    ) {
        self.instance = instance
        self.posNode = posNode
        self.negNode = negNode
        self.sensePosNode = sensePosNode
        self.senseNegNode = senseNegNode
        self.onResistance = onResistance
        self.offResistance = offResistance
        self.thresholdCurrent = thresholdCurrent
        self.hysteresisCurrent = hysteresisCurrent
        self.senseBranch = senseBranch
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        stampSenseBranch(into: &stamper)
        let point = operatingPoint(state: state)
        stamper.stampConductance(
            node1: posNode,
            node2: negNode,
            conductance: point.conductance
        )
        stampControlSensitivity(into: &stamper, point: point)
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        stampSenseBranch(into: &stamper)
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

    private func stampSenseBranch(into stamper: inout MatrixStamper) {
        stamper.stampVoltageSource(
            posNode: sensePosNode,
            negNode: senseNegNode,
            branch: senseBranch,
            voltage: 0.0
        )
    }

    private func stampSenseBranch(into stamper: inout ComplexMatrixStamper) {
        stamper.stampVoltageSource(
            posNode: sensePosNode,
            negNode: senseNegNode,
            branch: senseBranch,
            real: 0.0,
            imag: 0.0
        )
    }

    private func operatingPoint(state: SolutionState) -> OperatingPoint {
        let controlCurrent = state.current(through: senseBranch)
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
        guard let senseBranchIdx = stamper.branchIndex(senseBranch) else { return }

        let posIdx = stamper.nodeIndex(posNode)
        let negIdx = stamper.nodeIndex(negNode)

        if let posIdx {
            stamper.stampMatrix(posIdx, senseBranchIdx, point.controlGain)
        }
        if let negIdx {
            stamper.stampMatrix(negIdx, senseBranchIdx, -point.controlGain)
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
        guard let senseBranchIdx = stamper.branchIndex(senseBranch) else { return }

        let posIdx = stamper.nodeIndex(posNode)
        let negIdx = stamper.nodeIndex(negNode)

        if let posIdx {
            stamper.stampMatrix(posIdx, senseBranchIdx, point.controlGain, 0.0)
        }
        if let negIdx {
            stamper.stampMatrix(negIdx, senseBranchIdx, -point.controlGain, 0.0)
        }
    }

    private func switchPositionAndDerivative(controlCurrent: Double) -> (position: Double, derivative: Double) {
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

enum CurrentControlledSwitchTransition {
    private static let zeroHysteresisRelativeWidth = 1.0e-3
    private static let minimumReferenceCurrent = 1.0e-3

    static func width(
        hysteresisCurrent: Double,
        thresholdCurrent: Double,
        controlCurrent: Double
    ) -> Double {
        let hysteresisWidth = abs(hysteresisCurrent) / 8.0
        if hysteresisWidth > 0 {
            return hysteresisWidth
        }
        let referenceCurrent = max(abs(thresholdCurrent), abs(controlCurrent), minimumReferenceCurrent)
        return referenceCurrent * zeroHysteresisRelativeWidth
    }
}

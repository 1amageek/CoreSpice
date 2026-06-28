import Foundation
import CoreSpiceIR

/// A smooth voltage-controlled switch bound to circuit nodes.
public struct BoundVoltageControlledSwitch: BoundDevice, Sendable {

    public let instance: Instance
    private let posNode: Node
    private let negNode: Node
    private let controlPosNode: Node
    private let controlNegNode: Node
    private let onResistance: Double
    private let offResistance: Double
    private let threshold: Double
    private let hysteresis: Double

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
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        stamper.stampConductance(
            node1: posNode,
            node2: negNode,
            conductance: conductance(state: state)
        )
    }

    public func stampAC(into stamper: inout ComplexMatrixStamper, state: SolutionState, omega: Double) {
        stamper.stampAdmittance(
            node1: posNode,
            node2: negNode,
            real: conductance(state: state),
            imag: 0.0
        )
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        stampDC(into: &stamper, state: state)
    }

    public func checkConvergence(state: SolutionState, previousState: SolutionState) -> ConvergenceResult {
        let currentConductance = conductance(state: state)
        let previousConductance = conductance(state: previousState)
        let delta = abs(currentConductance - previousConductance)
        let tolerance = max(1.0e-12, 1.0e-3 * max(abs(currentConductance), abs(previousConductance)))
        guard delta <= tolerance else {
            return .notConverged(maxDelta: delta, deviceName: instance.name)
        }
        return .converged
    }

    private func conductance(state: SolutionState) -> Double {
        let controlVoltage = state.voltage(at: controlPosNode) - state.voltage(at: controlNegNode)
        let switchPosition = switchPosition(controlVoltage: controlVoltage)
        let onConductance = 1.0 / onResistance
        let offConductance = 1.0 / offResistance
        return offConductance + (onConductance - offConductance) * switchPosition
    }

    private func switchPosition(controlVoltage: Double) -> Double {
        let transitionWidth = max(abs(hysteresis) / 8.0, 1.0e-3)
        let normalized = clamp((controlVoltage - threshold) / transitionWidth, lower: -80.0, upper: 80.0)
        return 1.0 / (1.0 + exp(-normalized))
    }

    private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}

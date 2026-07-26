import CoreSpiceIR

/// A nonlinear current-output behavioral source.
public struct BoundBehavioralCurrentSource: BoundDevice, Sendable {
    public let instance: Instance

    private let positiveNodeIndex: Int?
    private let negativeNodeIndex: Int?
    private let evaluator: BehavioralExpressionEvaluator

    init(
        instance: Instance,
        positiveNodeIndex: Int?,
        negativeNodeIndex: Int?,
        evaluator: BehavioralExpressionEvaluator
    ) {
        self.instance = instance
        self.positiveNodeIndex = positiveNodeIndex
        self.negativeNodeIndex = negativeNodeIndex
        self.evaluator = evaluator
    }

    public func stampDC(into stamper: inout MatrixStamper, state: SolutionState) {
        stamp(into: &stamper, state: state, time: 0)
    }

    public func stampAC(
        into stamper: inout ComplexMatrixStamper,
        state: SolutionState,
        omega: Double
    ) {
        for dependencyIndex in evaluator.dependencyIndices {
            let derivative = evaluator.evaluate(
                state: state,
                time: 0,
                differentiating: dependencyIndex
            ).derivative
            stampDerivative(
                dependencyIndex: dependencyIndex,
                derivative: derivative,
                into: &stamper
            )
        }
    }

    public func stampTransient(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        integration: IntegrationState
    ) {
        stamp(into: &stamper, state: state, time: integration.currentTime)
    }

    public func checkConvergence(
        state: SolutionState,
        previousState: SolutionState
    ) -> ConvergenceResult {
        let current = evaluator.evaluate(state: state, time: 0).value
        let previous = evaluator.evaluate(state: previousState, time: 0).value
        let delta = abs(current - previous)
        let tolerance = 1e-12 + 1e-6 * max(abs(current), abs(previous))
        return delta <= tolerance
            ? .converged
            : .notConverged(maxDelta: delta, deviceName: instance.name)
    }

    private func stamp(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        time: Double
    ) {
        var equivalentCurrent = evaluator.evaluate(state: state, time: time).value
        for dependencyIndex in evaluator.dependencyIndices {
            let derivative = evaluator.evaluate(
                state: state,
                time: time,
                differentiating: dependencyIndex
            ).derivative
            stampDerivative(
                dependencyIndex: dependencyIndex,
                derivative: derivative,
                into: &stamper
            )
            equivalentCurrent -= derivative * state.value(at: dependencyIndex)
        }
        if let positiveNodeIndex {
            stamper.stampRHS(positiveNodeIndex, -equivalentCurrent)
        }
        if let negativeNodeIndex {
            stamper.stampRHS(negativeNodeIndex, equivalentCurrent)
        }
    }

    private func stampDerivative(
        dependencyIndex: Int,
        derivative: Double,
        into stamper: inout MatrixStamper
    ) {
        if let positiveNodeIndex {
            stamper.stampMatrix(positiveNodeIndex, dependencyIndex, derivative)
        }
        if let negativeNodeIndex {
            stamper.stampMatrix(negativeNodeIndex, dependencyIndex, -derivative)
        }
    }

    private func stampDerivative(
        dependencyIndex: Int,
        derivative: Double,
        into stamper: inout ComplexMatrixStamper
    ) {
        if let positiveNodeIndex {
            stamper.stampMatrix(positiveNodeIndex, dependencyIndex, derivative, 0)
        }
        if let negativeNodeIndex {
            stamper.stampMatrix(negativeNodeIndex, dependencyIndex, -derivative, 0)
        }
    }
}

import CoreSpiceIR

/// A nonlinear voltage-output behavioral source.
public struct BoundBehavioralVoltageSource: BoundDevice, Sendable {
    public let instance: Instance

    private let positiveNodeIndex: Int?
    private let negativeNodeIndex: Int?
    private let branchIndex: Int
    private let evaluator: BehavioralExpressionEvaluator

    init(
        instance: Instance,
        positiveNodeIndex: Int?,
        negativeNodeIndex: Int?,
        branchIndex: Int,
        evaluator: BehavioralExpressionEvaluator
    ) {
        self.instance = instance
        self.positiveNodeIndex = positiveNodeIndex
        self.negativeNodeIndex = negativeNodeIndex
        self.branchIndex = branchIndex
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
        stampOutputTopology(into: &stamper)
        for dependencyIndex in evaluator.dependencyIndices {
            let derivative = evaluator.evaluate(
                state: state,
                time: 0,
                differentiating: dependencyIndex
            ).derivative
            stamper.stampMatrix(branchIndex, dependencyIndex, -derivative, 0)
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
        let tolerance = 1e-9 + 1e-6 * max(abs(current), abs(previous))
        return delta <= tolerance
            ? .converged
            : .notConverged(maxDelta: delta, deviceName: instance.name)
    }

    private func stamp(
        into stamper: inout MatrixStamper,
        state: SolutionState,
        time: Double
    ) {
        stampOutputTopology(into: &stamper)
        var equivalentSource = evaluator.evaluate(state: state, time: time).value
        for dependencyIndex in evaluator.dependencyIndices {
            let derivative = evaluator.evaluate(
                state: state,
                time: time,
                differentiating: dependencyIndex
            ).derivative
            stamper.stampMatrix(branchIndex, dependencyIndex, -derivative)
            equivalentSource -= derivative * state.value(at: dependencyIndex)
        }
        stamper.stampRHS(branchIndex, equivalentSource)
    }

    private func stampOutputTopology(into stamper: inout MatrixStamper) {
        if let positiveNodeIndex {
            stamper.stampMatrix(positiveNodeIndex, branchIndex, 1)
            stamper.stampMatrix(branchIndex, positiveNodeIndex, 1)
        }
        if let negativeNodeIndex {
            stamper.stampMatrix(negativeNodeIndex, branchIndex, -1)
            stamper.stampMatrix(branchIndex, negativeNodeIndex, -1)
        }
    }

    private func stampOutputTopology(into stamper: inout ComplexMatrixStamper) {
        if let positiveNodeIndex {
            stamper.stampMatrix(positiveNodeIndex, branchIndex, 1, 0)
            stamper.stampMatrix(branchIndex, positiveNodeIndex, 1, 0)
        }
        if let negativeNodeIndex {
            stamper.stampMatrix(negativeNodeIndex, branchIndex, -1, 0)
            stamper.stampMatrix(branchIndex, negativeNodeIndex, -1, 0)
        }
    }
}

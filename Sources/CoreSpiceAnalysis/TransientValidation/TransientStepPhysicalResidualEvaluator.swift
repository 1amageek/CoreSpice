import CoreSpiceDevices
import CoreSpiceIR

/// Binds one trial's original equations to its immutable accepted history.
internal struct TransientStepPhysicalResidualEvaluator: NonlinearPhysicalResidualEvaluating {
    let evaluator: any TransientPhysicalResidualEvaluating
    let previousVariables: [Double]
    let twoPreviousVariables: [Double]
    let variableMap: [MNAVariable: Int]
    let integration: IntegrationState

    func accumulateResidual(state: SolutionState, add: (Int, Double) -> Void) throws {
        try evaluator.accumulateResidual(state: SolutionState(variables: state.variables,
            previousVariables: previousVariables, twoPreviousVariables: twoPreviousVariables, variableMap: variableMap),
            integration: integration, add: add)
    }
}

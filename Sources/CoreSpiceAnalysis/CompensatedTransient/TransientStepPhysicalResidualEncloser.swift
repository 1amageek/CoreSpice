import CoreSpiceDevices
import CoreSpiceIR

/// Attaches immutable accepted paired history to one Newton trial.
internal struct TransientStepPhysicalResidualEncloser: NonlinearPhysicalResidualEnclosing {
    let evaluator: any TransientPhysicalResidualEnclosing
    let previousVariables: [Double]
    let twoPreviousVariables: [Double]
    let previousLowComponents: [Double]
    let twoPreviousLowComponents: [Double]
    let variableMap: [MNAVariable: Int]
    let integration: IntegrationState

    func accumulateResidualEnclosure(state: SolutionState, add: (Int, CompensatedValue, Double) -> Void) throws {
        try evaluator.accumulateResidualEnclosure(state: SolutionState(variables: state.variables,
            previousVariables: previousVariables, twoPreviousVariables: twoPreviousVariables,
            variableMap: variableMap, variableLowComponents: state.variableLowComponents,
            previousVariableLowComponents: previousLowComponents,
            twoPreviousVariableLowComponents: twoPreviousLowComponents), integration: integration, add: add)
    }
}

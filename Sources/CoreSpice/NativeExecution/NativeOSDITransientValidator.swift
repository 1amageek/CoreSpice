import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI

/// Combines original device transient terms before accepted history is committed.
internal struct NativeOSDITransientValidator: TransientPhysicalResidualEvaluating {
    let contributors: [any TransientPhysicalResidualContributing]
    let rows: [DCEquationRowPolicy]
    let workspace: NativePhysicalResidualWorkspace
    let cancellation: CancellationToken
    var prior: (any TransientPhysicalResidualValidating)? = nil
    var canonical: NativeOSDICanonicalTransientValidator? = nil
    var sourceFactBudget: TransientExecutionBudget? = nil
    var sourceFactWork: Int = 0

    func validate(state: SolutionState, integration: IntegrationState) throws {
        defer { canonical?.invalidateSourceFacts() }
        try prior?.validate(state: state, integration: integration)
        try NativeOSDIPhysicalValidator.validate(state: state, rows: rows, cancellation: cancellation, workspace: workspace) { add in
            try accumulateResidual(state: state, integration: integration, add: add)
        }
        try canonical?.validate(state: state, integration: integration)
    }

    func accumulateResidual(state: SolutionState, integration: IntegrationState, add: (Int, Double) -> Void) throws {
        var completed = false
        defer { if !completed { canonical?.invalidateSourceFacts() } }
        try sourceFactBudget?.chargeWork(sourceFactWork)
        guard state.variables.count == rows.count, state.variables.allSatisfy(\.isFinite) else {
            throw OSDIAdapterFailure.nonfiniteEvaluation
        }
        for contributor in contributors {
            try NativeCircuitExecution.check(cancellation)
            var invalid = false
            try contributor.accumulateTransientPhysicalResidual(state: state, integration: integration) { row, value in
                guard rows.indices.contains(row), value.isFinite else { invalid = true; return }
                add(row, value)
            }
            guard !invalid else { throw OSDIAdapterFailure.nonfiniteEvaluation }
        }
        try NativeCircuitExecution.check(cancellation)
        completed = true
    }
}

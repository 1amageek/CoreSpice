import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceOSDI

/// Supplies complete original device terms to Analysis's fresh enclosed physical gate.
internal struct NativeOSDITransientEncloser: TransientPhysicalResidualEnclosing {
    let contributors: [any TransientPhysicalResidualEnclosureContributing]
    let rowCount: Int
    let cancellation: CancellationToken
    let prior: (any TransientPhysicalResidualValidating)?
    var canonical: NativeOSDICanonicalTransientValidator? = nil
    var sourceFactBudget: TransientExecutionBudget? = nil
    var sourceFactWork: Int = 0

    func accumulateResidualEnclosure(state: SolutionState, integration: IntegrationState,
        add: (Int, CompensatedValue, Double) -> Void) throws {
        var completed = false
        defer { if !completed { canonical?.invalidateSourceFacts() } }
        try sourceFactBudget?.chargeWork(sourceFactWork)
        guard state.variables.count == rowCount, state.variableLowComponents?.count == rowCount else {
            throw OSDIAdapterFailure.invalidMatrixMapping
        }
        for contributor in contributors {
            try NativeCircuitExecution.check(cancellation)
            var invalid = false
            try contributor.accumulateTransientPhysicalResidualEnclosure(state: state, integration: integration) { row, center, radius in
                guard row >= 0, row < rowCount, radius.isFinite, radius >= 0 else { invalid = true; return }
                add(row, center, radius)
            }
            guard !invalid else { throw OSDIAdapterFailure.nonfiniteEvaluation }
        }
        try NativeCircuitExecution.check(cancellation)
        completed = true
    }

    func validate(state: SolutionState, integration: IntegrationState) throws {
        defer { canonical?.invalidateSourceFacts() }
        // Analysis has just certified freshly accumulated original equations under every row tolerance.
        // Canonical decomposition consumes the same complete OSDI source facts when its exact key matches.
        try NativeCircuitExecution.check(cancellation)
        try prior?.validate(state: state, integration: integration)
        try canonical?.validate(state: state, integration: integration)
        try NativeCircuitExecution.check(cancellation)
    }
}

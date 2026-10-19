import CoreSpiceCompile
import CoreSpiceEvent

/// Composes the existing run owners without creating an independent resource budget.
package struct AnalysisLinearSolverControl: LinearSolverExecutionControlling {
    let budget: TransientExecutionBudget?
    let cancellation: CancellationToken
    let storage: (any AnalysisResultStorageAccounting)?

    package static func make(budget: TransientExecutionBudget?, cancellation: CancellationToken,
        storage: (any AnalysisResultStorageAccounting)?) -> (any LinearSolverExecutionControlling)? {
        guard budget != nil || storage != nil else { return nil }
        return AnalysisLinearSolverControl(budget: budget, cancellation: cancellation, storage: storage)
    }

    package func checkpoint(workUnits: Int) throws {
        try checkCancellation()
        guard workUnits >= 0 else {
            throw TransientExecutionError.invalidLimit(name: "workUnits", value: workUnits)
        }
        try budget?.chargeWork(workUnits)
        try checkCancellation()
    }

    package func reserveStorage(byteCount: Int) throws -> any Sendable {
        try checkCancellation()
        guard byteCount >= 0 else {
            throw TransientExecutionError.arithmeticOverflow("solver storage byte count")
        }
        let lease: any Sendable
        if let storage {
            lease = try storage.reserveTemporaryBytes(UInt64(byteCount))
        } else {
            lease = UnaccountedStorage()
        }
        try checkCancellation()
        return lease
    }

    private func checkCancellation() throws {
        if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
    }

    private struct UnaccountedStorage: Sendable {}
}

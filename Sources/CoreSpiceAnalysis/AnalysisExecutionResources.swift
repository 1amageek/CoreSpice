import Synchronization

/// Explicit invocation owner for cumulative numerical work across independent cases.
///
/// Solve-attempt, Newton, work and matrix-dimension ceilings are invocation-wide.
/// Accepted-step and saved-scalar ceilings remain local to each created case budget.
/// Retained output storage is accounted by the caller's separate storage owner.
public final class AnalysisExecutionResources: Sendable {
    public let limits: TransientExecutionLimits
    private let state = Mutex(AnalysisExecutionUsage(solveAttempts: 0, newtonIterations: 0,
        workUnits: 0, maximumMatrixDimension: 0))

    public init(limits: TransientExecutionLimits) throws {
        try limits.validate()
        self.limits = limits
    }

    public var usage: AnalysisExecutionUsage { state.withLock { $0 } }

    /// Starts a case with its own statistics and output ceilings, sharing invocation numerical ceilings.
    package func budget(dimension: Int, nonZeroCount: Int, deviceCount: Int) throws -> TransientExecutionBudget {
        try TransientExecutionBudget(limits: limits, dimension: dimension,
            nonZeroCount: nonZeroCount, deviceCount: deviceCount, invocationResources: self)
    }

    /// Called only after complete local validation, with case -> invocation lock ordering.
    package func admit(solveAttempts: Int = 0, newtonIterations: Int = 0,
                       workUnits: Int = 0, dimension: Int) throws {
        guard solveAttempts >= 0, newtonIterations >= 0, workUnits >= 0, dimension > 0 else {
            throw AnalysisError.invalidConfiguration("Invocation numerical admission delta is invalid")
        }
        try state.withLock { current in
            let attempts = try TransientExecutionBudget.add(current.solveAttempts, solveAttempts, "invocation solveAttempts")
            let iterations = try TransientExecutionBudget.add(current.newtonIterations, newtonIterations, "invocation newtonIterations")
            let work = try TransientExecutionBudget.add(current.workUnits, workUnits, "invocation workUnits")
            try TransientExecutionBudget.admit(attempts, limit: limits.maximumSolveAttempts, resource: "invocation.solveAttempts")
            try TransientExecutionBudget.admit(iterations, limit: limits.maximumNewtonIterations, resource: "invocation.newtonIterations")
            try TransientExecutionBudget.admit(work, limit: limits.maximumWorkUnits, resource: "invocation.workUnits")
            try TransientExecutionBudget.admit(dimension, limit: limits.maximumMatrixDimension, resource: "invocation.matrixDimension")
            current = AnalysisExecutionUsage(solveAttempts: attempts, newtonIterations: iterations,
                workUnits: work, maximumMatrixDimension: max(current.maximumMatrixDimension, dimension))
        }
    }
}

/// Cumulative numerical work admitted across cases in one explicit invocation.
public struct AnalysisExecutionUsage: Sendable, Equatable {
    public let solveAttempts: Int
    public let newtonIterations: Int
    public let workUnits: Int
    public let maximumMatrixDimension: Int
}

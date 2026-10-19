import CoreSpiceAnalysis

/// Invocation-wide numerical counters, kept separate from each case's own statistics.
struct CoreSpiceCLINumericalUsage: Codable, Sendable, Equatable {
    let solveAttempts: Int
    let newtonIterations: Int
    let workUnits: Int
    let maximumMatrixDimension: Int
    init(_ statistics: TransientExecutionStatistics) {
        solveAttempts = statistics.solveAttempts; newtonIterations = statistics.newtonIterations
        workUnits = statistics.workUnits; maximumMatrixDimension = statistics.matrixDimension
    }
    init(_ usage: AnalysisExecutionUsage) {
        solveAttempts = usage.solveAttempts; newtonIterations = usage.newtonIterations
        workUnits = usage.workUnits; maximumMatrixDimension = usage.maximumMatrixDimension
    }
}

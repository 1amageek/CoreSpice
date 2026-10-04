import Foundation

/// Actual admitted work across initialization, recovery and transient stepping.
public struct TransientExecutionStatistics: Sendable, Hashable, Codable {
    public let acceptedSteps: Int
    public let rejectedSteps: Int
    public let solveAttempts: Int
    public let newtonIterations: Int
    public let savedScalars: Int
    public let workUnits: Int
    public let matrixDimension: Int
}

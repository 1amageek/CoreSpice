import Foundation

/// Caller-owned ceilings for a complete transient run, including its initial DC solve.
/// Callers explicitly select limits; no resource policy is inferred from machine integer capacity.
public struct TransientExecutionLimits: Sendable, Hashable, Codable {
    public var maximumAcceptedSteps: Int
    public var maximumSolveAttempts: Int
    public var maximumNewtonIterations: Int
    /// Includes each saved time plus every saved MNA variable, including the initial point.
    public var maximumSavedScalars: Int
    public var maximumMatrixDimension: Int
    public var maximumWorkUnits: Int
    public var maximumBreakpoints: Int

    public init(maximumAcceptedSteps: Int, maximumSolveAttempts: Int, maximumNewtonIterations: Int,
                maximumSavedScalars: Int, maximumMatrixDimension: Int, maximumWorkUnits: Int,
                maximumBreakpoints: Int) {
        self.maximumAcceptedSteps = maximumAcceptedSteps
        self.maximumSolveAttempts = maximumSolveAttempts
        self.maximumNewtonIterations = maximumNewtonIterations
        self.maximumSavedScalars = maximumSavedScalars
        self.maximumMatrixDimension = maximumMatrixDimension
        self.maximumWorkUnits = maximumWorkUnits
        self.maximumBreakpoints = maximumBreakpoints
    }

    public func validate() throws {
        for (name, value) in [
            ("maximumAcceptedSteps", maximumAcceptedSteps), ("maximumSolveAttempts", maximumSolveAttempts),
            ("maximumNewtonIterations", maximumNewtonIterations), ("maximumSavedScalars", maximumSavedScalars),
            ("maximumMatrixDimension", maximumMatrixDimension), ("maximumWorkUnits", maximumWorkUnits),
            ("maximumBreakpoints", maximumBreakpoints)
        ] {
            guard value > 0 else { throw TransientExecutionError.invalidLimit(name: name, value: value) }
        }
    }
}

import CoreSpiceAnalysis

/// This test target owns finite ceilings for its admitted fixture sizes and numerical sweeps.
extension TransientExecutionLimits {
    static var validationFixture: TransientExecutionLimits {
        TransientExecutionLimits(maximumAcceptedSteps: 250_000, maximumSolveAttempts: 1_000_000,
            maximumNewtonIterations: 5_000_000, maximumSavedScalars: 20_000_000,
            maximumMatrixDimension: 2_048, maximumWorkUnits: 1_000_000_000_000_000,
            maximumBreakpoints: 250_000)
    }
}

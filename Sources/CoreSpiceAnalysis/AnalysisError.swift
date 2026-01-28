/// Errors that can occur during circuit analysis.
///
/// Each case carries contextual information to aid diagnostics
/// and error reporting.
public enum AnalysisError: Error, Sendable {

    /// Newton-Raphson iteration failed to converge within the allowed iterations.
    ///
    /// - Parameters:
    ///   - iterations: The number of iterations attempted before giving up.
    ///   - residualNorm: The infinity-norm of the residual at the final iteration.
    case convergenceFailure(iterations: Int, residualNorm: Double)

    /// The MNA system matrix is singular and cannot be factorized.
    case singularMatrix

    /// The analysis was cancelled through the cancellation token.
    case cancelled

    /// The analysis configuration is invalid.
    ///
    /// - Parameter message: A description of what is wrong with the configuration.
    case invalidConfiguration(String)

    /// The transient integration timestep has been reduced below the minimum.
    ///
    /// - Parameter timestep: The timestep that was too small.
    case timestepTooSmall(Double)

    /// An unexpected internal error occurred.
    ///
    /// - Parameter message: A description of the internal error.
    case internalError(String)
}

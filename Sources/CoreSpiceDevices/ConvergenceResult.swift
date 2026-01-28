/// Result of a per-device Newton-Raphson convergence check.
public enum ConvergenceResult: Sendable {
    /// The device has converged within tolerances.
    case converged
    /// The device has not yet converged.
    case notConverged(maxDelta: Double, deviceName: String)
}

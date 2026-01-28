/// Configuration parameters for Newton-Raphson convergence checks.
///
/// The default values follow standard SPICE conventions:
/// - `abstol`: absolute current tolerance (1e-12 A)
/// - `reltol`: relative tolerance (0.1%)
/// - `vntol`: voltage node tolerance (1e-6 V)
/// - `gmin`: minimum conductance added to the diagonal (1e-12 S)
public struct ConvergenceConfig: Sendable {

    /// Absolute current tolerance.
    public var abstol: Double

    /// Relative tolerance.
    public var reltol: Double

    /// Voltage node tolerance.
    public var vntol: Double

    /// Maximum number of Newton-Raphson iterations per solve.
    public var maxIterations: Int

    /// Minimum conductance added to diagonal entries for numerical stability.
    public var gmin: Double

    public init(
        abstol: Double = 1e-12,
        reltol: Double = 1e-3,
        vntol: Double = 1e-6,
        maxIterations: Int = 50,
        gmin: Double = 1e-12
    ) {
        self.abstol = abstol
        self.reltol = reltol
        self.vntol = vntol
        self.maxIterations = maxIterations
        self.gmin = gmin
    }

    /// Tests whether the Newton update vector `dx` is small enough
    /// relative to the current solution `x` to declare convergence.
    ///
    /// For each element `i`, checks: `|dx[i]| < reltol * |x[i]| + vntol`.
    ///
    /// - Parameters:
    ///   - dx: The Newton update vector (difference between successive iterates).
    ///   - x: The current solution vector.
    /// - Returns: `true` if all elements satisfy the convergence criterion.
    public func isConverged(dx: [Double], x: [Double]) -> Bool {
        for i in 0..<dx.count {
            if abs(dx[i]) > reltol * abs(x[i]) + vntol {
                return false
            }
        }
        return true
    }
}

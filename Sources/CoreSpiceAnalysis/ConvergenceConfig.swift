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

    /// Minimum damping factor for Newton-Raphson adaptive damping.
    /// When divergence is detected, the damping factor is clamped to `[minDamping, 1.0]`.
    public var minDamping: Double

    public init(
        abstol: Double = 1e-12,
        reltol: Double = 1e-3,
        vntol: Double = 1e-6,
        maxIterations: Int = 50,
        gmin: Double = 1e-12,
        minDamping: Double = 0.1
    ) {
        self.abstol = abstol
        self.reltol = reltol
        self.vntol = vntol
        self.maxIterations = maxIterations
        self.gmin = gmin
        self.minDamping = minDamping
    }

    /// Tests whether the Newton update vector `dx` is small enough
    /// relative to the current solution `x` to declare convergence.
    ///
    /// For each element `i`, checks: `|dx[i]| < reltol * |x[i]| + tol`
    /// where `tol` is `vntol` for voltage variables and `abstol` for
    /// branch current variables.
    ///
    /// - Parameters:
    ///   - dx: The Newton update vector (difference between successive iterates).
    ///   - x: The current solution vector.
    ///   - branchCurrentIndices: Set of indices corresponding to branch currents.
    ///     When nil, all variables use `vntol`.
    /// - Returns: `true` if all elements satisfy the convergence criterion.
    public func isConverged(dx: [Double], x: [Double], branchCurrentIndices: Set<Int>? = nil) -> Bool {
        for i in 0..<dx.count {
            let tol: Double
            if let indices = branchCurrentIndices, indices.contains(i) {
                tol = reltol * abs(x[i]) + abstol
            } else {
                tol = reltol * abs(x[i]) + vntol
            }
            if abs(dx[i]) > tol {
                return false
            }
        }
        return true
    }
}

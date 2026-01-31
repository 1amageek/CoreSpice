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

    /// Tests whether the solution change between two Newton iterates is
    /// small enough to declare convergence.
    ///
    /// For each element `i`, checks:
    /// `|currentX[i] - previousX[i]| < reltol * |currentX[i]| + tol`
    /// where `tol` is `vntol` for voltage variables and `abstol` for
    /// branch current variables.
    ///
    /// - Parameters:
    ///   - previousX: The solution vector from the previous Newton iterate.
    ///   - currentX: The current solution vector.
    ///   - branchCurrentIndices: Set of indices corresponding to branch currents.
    ///     When nil, all variables use `vntol`.
    /// - Returns: `true` if all elements satisfy the convergence criterion.
    public func isConverged(
        previousX: [Double],
        currentX: [Double],
        branchCurrentIndices: Set<Int>? = nil
    ) -> Bool {
        for i in 0..<currentX.count {
            let delta = currentX[i] - previousX[i]
            let tol: Double
            if let indices = branchCurrentIndices, indices.contains(i) {
                tol = reltol * abs(currentX[i]) + abstol
            } else {
                tol = reltol * abs(currentX[i]) + vntol
            }
            if abs(delta) > tol {
                return false
            }
        }
        return true
    }
}

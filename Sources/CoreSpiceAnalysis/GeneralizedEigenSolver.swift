import Accelerate
import CoreSpiceCompile

/// Solves the generalized eigenvalue problem `A * x = λ * B * x`
/// using LAPACK's `dggev_` routine (QZ algorithm).
///
/// This solver is used by ``PoleZeroAnalysis`` to find the poles and zeros
/// of circuit transfer functions by computing eigenvalues of matrix pencils
/// `(G, C)` derived from the MNA conductance and susceptance matrices.
struct GeneralizedEigenSolver {

    /// The result of a generalized eigenvalue computation.
    struct EigenResult {
        /// The finite eigenvalues (where `|β| > threshold`).
        /// Infinite eigenvalues (`β ≈ 0`) are excluded.
        let eigenvalues: [ComplexPair]
    }

    /// Errors from the eigenvalue solver.
    enum EigenSolverError: Error {
        /// LAPACK's `dggev_` returned a non-zero info code.
        case lapackFailed(info: Int)
        /// The matrix dimension is zero.
        case emptyMatrix
    }

    /// Solves the generalized eigenvalue problem `A * x = λ * B * x`.
    ///
    /// Both matrices are provided as column-major flat arrays of size `N × N`.
    /// The routine computes eigenvalues `λ_j = (αR_j + i·αI_j) / β_j`.
    /// Eigenvalues with `|β_j|` below a threshold are considered infinite
    /// and excluded from the result.
    ///
    /// - Parameters:
    ///   - matrixA: Matrix A in column-major flat array (N×N).
    ///   - matrixB: Matrix B in column-major flat array (N×N).
    ///   - dimension: The matrix dimension N.
    /// - Returns: The finite eigenvalues.
    /// - Throws: ``EigenSolverError`` on failure.
    static func solve(
        matrixA: [Double],
        matrixB: [Double],
        dimension: Int
    ) throws -> EigenResult {
        guard dimension > 0 else {
            throw EigenSolverError.emptyMatrix
        }

        var n = __CLPK_integer(dimension)
        var a = matrixA
        var b = matrixB
        var lda = n
        var ldb = n

        var alphar = [Double](repeating: 0, count: dimension)
        var alphai = [Double](repeating: 0, count: dimension)
        var beta = [Double](repeating: 0, count: dimension)

        // No eigenvectors needed
        var jobvl = Int8(UnicodeScalar("N").value)
        var jobvr = Int8(UnicodeScalar("N").value)

        var vl = [Double](repeating: 0, count: 1)
        var ldvl: __CLPK_integer = 1
        var vr = [Double](repeating: 0, count: 1)
        var ldvr: __CLPK_integer = 1

        // Workspace query
        var lwork: __CLPK_integer = -1
        var workQuery = [Double](repeating: 0, count: 1)
        var info: __CLPK_integer = 0

        dggev_(
            &jobvl, &jobvr, &n,
            &a, &lda,
            &b, &ldb,
            &alphar, &alphai, &beta,
            &vl, &ldvl, &vr, &ldvr,
            &workQuery, &lwork, &info
        )

        guard info == 0 else {
            throw EigenSolverError.lapackFailed(info: Int(info))
        }

        lwork = __CLPK_integer(workQuery[0])
        var work = [Double](repeating: 0, count: Int(lwork))

        // Reset arrays since workspace query may have modified them
        a = matrixA
        b = matrixB

        // Actual computation
        dggev_(
            &jobvl, &jobvr, &n,
            &a, &lda,
            &b, &ldb,
            &alphar, &alphai, &beta,
            &vl, &ldvl, &vr, &ldvr,
            &work, &lwork, &info
        )

        guard info == 0 else {
            throw EigenSolverError.lapackFailed(info: Int(info))
        }

        // Extract finite eigenvalues: λ_j = (alphar[j] + i·alphai[j]) / beta[j]
        var eigenvalues: [ComplexPair] = []
        let threshold = 1e-30
        for j in 0..<dimension {
            if abs(beta[j]) > threshold {
                eigenvalues.append(ComplexPair(
                    real: alphar[j] / beta[j],
                    imag: alphai[j] / beta[j]
                ))
            }
        }

        return EigenResult(eigenvalues: eigenvalues)
    }
}

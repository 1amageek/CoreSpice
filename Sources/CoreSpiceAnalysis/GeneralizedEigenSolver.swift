import CoreSpiceCompile
import CoreSpiceLAPACK

/// Solves the generalized eigenvalue problem `A * x = λ * B * x`
/// using LAPACK's `dggev` routine (QZ algorithm).
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
        /// LAPACK's `dggev` returned a non-zero info code.
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

        let n = CoreSpiceLAPACKInteger(dimension)
        var a = matrixA
        var b = matrixB
        let lda = n
        let ldb = n

        var alphar = [Double](repeating: 0, count: dimension)
        var alphai = [Double](repeating: 0, count: dimension)
        var beta = [Double](repeating: 0, count: dimension)

        // No eigenvectors needed
        let jobvl = Int8(UnicodeScalar("N").value)
        let jobvr = Int8(UnicodeScalar("N").value)

        var vl = [Double](repeating: 0, count: 1)
        let ldvl: CoreSpiceLAPACKInteger = 1
        var vr = [Double](repeating: 0, count: 1)
        let ldvr: CoreSpiceLAPACKInteger = 1

        // Workspace query
        var lwork: CoreSpiceLAPACKInteger = -1
        var workQuery = [Double](repeating: 0, count: 1)
        var info = coreSpiceLAPACKGeneralizedEigenvalues(
            jobvl, jobvr, n,
            &a, lda,
            &b, ldb,
            &alphar, &alphai, &beta,
            &vl, ldvl, &vr, ldvr,
            &workQuery, lwork
        )

        guard info == 0 else {
            throw EigenSolverError.lapackFailed(info: Int(info))
        }

        lwork = CoreSpiceLAPACKInteger(workQuery[0])
        var work = [Double](repeating: 0, count: Int(lwork))

        // Reset arrays since workspace query may have modified them
        a = matrixA
        b = matrixB

        // Actual computation
        info = coreSpiceLAPACKGeneralizedEigenvalues(
            jobvl, jobvr, n,
            &a, lda,
            &b, ldb,
            &alphar, &alphai, &beta,
            &vl, ldvl, &vr, ldvr,
            &work, lwork
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

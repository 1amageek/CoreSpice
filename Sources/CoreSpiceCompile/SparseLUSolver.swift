/// LU decomposition solver with partial pivoting for real sparse matrices.
///
/// Internally converts the sparse matrix to a dense representation for
/// factorization. This is efficient for the moderate matrix sizes typical
/// of circuit simulation (up to a few thousand nodes).
public struct SparseLUSolver: LinearSolver {

    private var dimension: Int = 0
    private var lower: [[Double]] = []
    private var upper: [[Double]] = []
    private var pivot: [Int] = []
    private var factorized: Bool = false

    public init() {}

    /// Factorizes the sparse matrix using LU decomposition with partial pivoting.
    ///
    /// The decomposition satisfies `P * A = L * U` where P is a row
    /// permutation, L is unit lower triangular, and U is upper triangular.
    ///
    /// - Throws: ``CompileError/singularMatrix`` if a zero pivot is encountered.
    public mutating func factorize(matrix: SparseMatrix) throws {
        let n = matrix.dimension
        dimension = n

        // Convert sparse matrix to dense column-major storage.
        var a = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for row in 0..<n {
            let start = matrix.structure.rowPointers[row]
            let end = matrix.structure.rowPointers[row + 1]
            for idx in start..<end {
                let col = matrix.structure.columnIndices[idx]
                a[row][col] = matrix.values[idx]
            }
        }

        // Initialize pivot as identity permutation.
        pivot = Array(0..<n)

        // Gaussian elimination with partial pivoting.
        for k in 0..<n {
            // Find pivot row: the row with the largest absolute value in column k.
            var maxVal = abs(a[k][k])
            var maxRow = k
            for i in (k + 1)..<n {
                let candidate = abs(a[i][k])
                if candidate > maxVal {
                    maxVal = candidate
                    maxRow = i
                }
            }

            if maxVal < 1e-15 {
                throw CompileError.singularMatrix
            }

            // Swap rows k and maxRow in both the matrix and pivot vector.
            if maxRow != k {
                a.swapAt(k, maxRow)
                pivot.swapAt(k, maxRow)
            }

            // Eliminate below the pivot.
            let pivotValue = a[k][k]
            for i in (k + 1)..<n {
                let factor = a[i][k] / pivotValue
                a[i][k] = factor  // Store L factor in place.
                for j in (k + 1)..<n {
                    a[i][j] -= factor * a[k][j]
                }
            }
        }

        // Extract L and U from the in-place factorization.
        lower = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        upper = Array(repeating: Array(repeating: 0.0, count: n), count: n)

        for i in 0..<n {
            lower[i][i] = 1.0  // Unit diagonal for L.
            for j in 0..<n {
                if j < i {
                    lower[i][j] = a[i][j]
                } else {
                    upper[i][j] = a[i][j]
                }
            }
        }

        factorized = true
    }

    /// Solves `A * x = rhs` using the stored LU factorization.
    ///
    /// Performs forward substitution (`L * y = P * rhs`) followed by
    /// backward substitution (`U * x = y`).
    ///
    /// - Throws: ``CompileError/singularMatrix`` if the solver has not been factorized.
    public func solve(rhs: [Double]) throws -> [Double] {
        guard factorized else {
            throw CompileError.singularMatrix
        }

        let n = dimension

        // Apply permutation: b = P * rhs.
        var b = Array(repeating: 0.0, count: n)
        for i in 0..<n {
            b[i] = rhs[pivot[i]]
        }

        // Forward substitution: L * y = b.
        var y = Array(repeating: 0.0, count: n)
        for i in 0..<n {
            var sum = b[i]
            for j in 0..<i {
                sum -= lower[i][j] * y[j]
            }
            y[i] = sum
        }

        // Backward substitution: U * x = y.
        var x = Array(repeating: 0.0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = y[i]
            for j in (i + 1)..<n {
                sum -= upper[i][j] * x[j]
            }
            x[i] = sum / upper[i][i]
        }

        return x
    }
}

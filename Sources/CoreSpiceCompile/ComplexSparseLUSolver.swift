/// LU decomposition solver with partial pivoting for complex sparse matrices.
///
/// Internally converts the sparse matrix to a dense representation for
/// factorization, mirroring ``SparseLUSolver`` but operating on
/// ``ComplexPair`` values.
public struct ComplexSparseLUSolver: ComplexLinearSolver {

    private var dimension: Int = 0
    private var lower: [[ComplexPair]] = []
    private var upper: [[ComplexPair]] = []
    private var pivot: [Int] = []
    private var factorized: Bool = false

    public init() {}

    /// Factorizes the complex sparse matrix using LU decomposition with partial pivoting.
    ///
    /// - Throws: ``CompileError/singularMatrix`` if a zero pivot is encountered.
    public mutating func factorize(matrix: ComplexSparseMatrix) throws {
        let n = matrix.dimension
        dimension = n

        // Convert sparse matrix to dense representation.
        var a = Array(
            repeating: Array(repeating: ComplexPair.zero, count: n),
            count: n
        )
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

        // Gaussian elimination with partial pivoting (by magnitude).
        for k in 0..<n {
            var maxMag = a[k][k].magnitude
            var maxRow = k
            for i in (k + 1)..<n {
                let candidate = a[i][k].magnitude
                if candidate > maxMag {
                    maxMag = candidate
                    maxRow = i
                }
            }

            if maxMag < 1e-15 {
                throw CompileError.singularMatrix
            }

            if maxRow != k {
                a.swapAt(k, maxRow)
                pivot.swapAt(k, maxRow)
            }

            let pivotValue = a[k][k]
            for i in (k + 1)..<n {
                let factor = a[i][k] / pivotValue
                a[i][k] = factor  // Store L factor in place.
                for j in (k + 1)..<n {
                    a[i][j] = a[i][j] - factor * a[k][j]
                }
            }
        }

        // Extract L (unit lower triangular) and U (upper triangular).
        lower = Array(
            repeating: Array(repeating: ComplexPair.zero, count: n),
            count: n
        )
        upper = Array(
            repeating: Array(repeating: ComplexPair.zero, count: n),
            count: n
        )

        for i in 0..<n {
            lower[i][i] = .one
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

    /// Solves `A * x = rhs` using the stored complex LU factorization.
    ///
    /// - Throws: ``CompileError/singularMatrix`` if the solver has not been factorized.
    public func solve(rhs: [ComplexPair]) throws -> [ComplexPair] {
        guard factorized else {
            throw CompileError.singularMatrix
        }

        let n = dimension

        // Apply permutation: b = P * rhs.
        var b = Array(repeating: ComplexPair.zero, count: n)
        for i in 0..<n {
            b[i] = rhs[pivot[i]]
        }

        // Forward substitution: L * y = b.
        var y = Array(repeating: ComplexPair.zero, count: n)
        for i in 0..<n {
            var sum = b[i]
            for j in 0..<i {
                sum = sum - lower[i][j] * y[j]
            }
            y[i] = sum
        }

        // Backward substitution: U * x = y.
        var x = Array(repeating: ComplexPair.zero, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = y[i]
            for j in (i + 1)..<n {
                sum = sum - upper[i][j] * x[j]
            }
            x[i] = sum / upper[i][i]
        }

        return x
    }
}

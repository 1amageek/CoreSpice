/// LU decomposition solver with partial pivoting for complex sparse matrices.
///
/// Uses symbolic analysis to predict fill-in and maintains sparse storage
/// throughout the factorization process. This provides O(nnz) complexity
/// instead of O(n²) for sparse matrices typical of AC circuit analysis.
public struct ComplexSparseLUSolver: ComplexLinearSolver {

    private var dimension: Int = 0
    private var symbolic: SymbolicAnalysis?
    private var lValues: [ComplexPair] = []
    private var uValues: [ComplexPair] = []
    private var pivot: [Int] = []
    private var factorized: Bool = false

    /// Whether to use AMD ordering for fill-reduction.
    public var useAMDOrdering: Bool = true

    public init() {}

    /// Creates a solver with explicit ordering control.
    ///
    /// - Parameter useAMDOrdering: Whether to compute AMD ordering (default: true).
    public init(useAMDOrdering: Bool) {
        self.useAMDOrdering = useAMDOrdering
    }

    /// Factorizes the complex sparse matrix using LU decomposition with partial pivoting.
    ///
    /// - Throws: ``CompileError/singularMatrix`` if a zero pivot is encountered.
    public mutating func factorize(matrix: ComplexSparseMatrix) throws {
        let n = matrix.dimension
        dimension = n

        if n == 0 {
            factorized = true
            return
        }

        // Perform symbolic analysis
        let ordering = useAMDOrdering
            ? AMDOrdering.compute(structure: matrix.structure)
            : Permutation.identity(size: n)
        symbolic = SymbolicAnalysis.analyze(structure: matrix.structure, ordering: ordering)

        guard let sym = symbolic else {
            throw CompileError.singularMatrix
        }

        // Apply ordering to matrix
        let permutedMatrix = matrix.permute(sym.permutation)

        // Use dense factorization for moderate-sized matrices
        if n < 500 {
            try factorizeDense(matrix: permutedMatrix)
        } else {
            try factorizeSparse(matrix: permutedMatrix, symbolic: sym)
        }

        factorized = true
    }

    /// Dense factorization for small matrices.
    private mutating func factorizeDense(matrix: ComplexSparseMatrix) throws {
        let n = matrix.dimension

        // Convert to dense
        var a = matrix.toDense()

        // Initialize pivot as identity permutation
        pivot = Array(0..<n)

        // Gaussian elimination with partial pivoting (by magnitude)
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
                a[i][k] = factor
                for j in (k + 1)..<n {
                    a[i][j] = a[i][j] - factor * a[k][j]
                }
            }
        }

        // Store L and U values in sparse format
        guard let sym = symbolic else { return }

        lValues = Array(repeating: .zero, count: sym.lColumnIndices.count)
        uValues = Array(repeating: .zero, count: sym.uColumnIndices.count)

        for row in 0..<n {
            let lStart = sym.lRowPointers[row]
            let lEnd = sym.lRowPointers[row + 1]
            for idx in lStart..<lEnd {
                let col = sym.lColumnIndices[idx]
                lValues[idx] = a[row][col]
            }

            let uStart = sym.uRowPointers[row]
            let uEnd = sym.uRowPointers[row + 1]
            for idx in uStart..<uEnd {
                let col = sym.uColumnIndices[idx]
                uValues[idx] = a[row][col]
            }
        }
    }

    /// Sparse factorization for large matrices with threshold pivoting.
    ///
    /// Uses threshold pivoting to maintain numerical stability while preserving
    /// sparsity benefits from AMD ordering. Row swaps occur only when the diagonal
    /// element is significantly smaller than the column maximum (by magnitude).
    private mutating func factorizeSparse(matrix: ComplexSparseMatrix, symbolic: SymbolicAnalysis) throws {
        let n = matrix.dimension
        let pivotThreshold = 0.1  // Swap if diagonal magnitude < 10% of column max

        lValues = Array(repeating: .zero, count: symbolic.lColumnIndices.count)
        uValues = Array(repeating: .zero, count: symbolic.uColumnIndices.count)
        pivot = Array(0..<n)

        // Row permutation: rowPerm[k] = which original matrix row is at position k
        var rowPerm = Array(0..<n)

        var rowWork = Array(repeating: ComplexPair.zero, count: n)
        var rowFlag = Array(repeating: -1, count: n)

        for k in 0..<n {
            // Clear work array
            for j in 0..<n where rowFlag[j] == k - 1 {
                rowWork[j] = .zero
            }

            // Load row rowPerm[k] from original matrix
            let origRow = rowPerm[k]
            loadRowFromMatrix(matrix: matrix, origRow: origRow, rowWork: &rowWork, rowFlag: &rowFlag, k: k)

            // Apply previous L rows to current row
            applyPreviousLRows(k: k, symbolic: symbolic, rowWork: &rowWork, rowFlag: &rowFlag)

            // --- Threshold Pivoting ---
            // Find maximum magnitude in column k for rows k to n-1
            let diagMag = rowWork[k].magnitude
            var maxMag = diagMag
            var maxRow = k

            for i in (k + 1)..<n {
                let origRowI = rowPerm[i]
                let valInColK = getValueInColumn(matrix: matrix, origRow: origRowI, col: k)
                if valInColK.magnitude > maxMag {
                    maxMag = valInColK.magnitude
                    maxRow = i
                }
            }

            // Swap rows if diagonal magnitude is too small compared to maximum
            if maxRow != k && diagMag < pivotThreshold * maxMag {
                // Swap row permutation
                rowPerm.swapAt(k, maxRow)
                pivot.swapAt(k, maxRow)

                // Reload row k with the new assignment
                for j in 0..<n where rowFlag[j] == k {
                    rowWork[j] = .zero
                }
                let newOrigRow = rowPerm[k]
                loadRowFromMatrix(matrix: matrix, origRow: newOrigRow, rowWork: &rowWork, rowFlag: &rowFlag, k: k)

                // Re-apply previous L rows
                applyPreviousLRows(k: k, symbolic: symbolic, rowWork: &rowWork, rowFlag: &rowFlag)
            }

            // Compute and store L values for column k
            let lStart = symbolic.lRowPointers[k]
            let lEnd = symbolic.lRowPointers[k + 1]

            for lIdx in lStart..<lEnd {
                let j = symbolic.lColumnIndices[lIdx]
                let ujjIdx = findUDiagonal(row: j, symbolic: symbolic)
                guard ujjIdx >= 0, uValues[ujjIdx].magnitude > 1e-15 else {
                    throw CompileError.singularMatrix
                }
                let lkj = rowWork[j] / uValues[ujjIdx]
                lValues[lIdx] = lkj
            }

            // Store U row
            let uStart = symbolic.uRowPointers[k]
            let uEnd = symbolic.uRowPointers[k + 1]
            for uIdx in uStart..<uEnd {
                let col = symbolic.uColumnIndices[uIdx]
                uValues[uIdx] = rowFlag[col] == k ? rowWork[col] : .zero
            }

            // Check diagonal
            let diagIdx = findUDiagonal(row: k, symbolic: symbolic)
            if diagIdx < 0 || uValues[diagIdx].magnitude < 1e-15 {
                throw CompileError.singularMatrix
            }
        }
    }

    /// Load a row from the original matrix into the work array.
    private func loadRowFromMatrix(
        matrix: ComplexSparseMatrix,
        origRow: Int,
        rowWork: inout [ComplexPair],
        rowFlag: inout [Int],
        k: Int
    ) {
        let mStart = matrix.structure.rowPointers[origRow]
        let mEnd = matrix.structure.rowPointers[origRow + 1]
        for idx in mStart..<mEnd {
            let col = matrix.structure.columnIndices[idx]
            rowWork[col] = matrix.values[idx]
            rowFlag[col] = k
        }
    }

    /// Get the value at (origRow, col) from the original matrix, or zero if not present.
    private func getValueInColumn(matrix: ComplexSparseMatrix, origRow: Int, col: Int) -> ComplexPair {
        let start = matrix.structure.rowPointers[origRow]
        let end = matrix.structure.rowPointers[origRow + 1]
        for idx in start..<end {
            if matrix.structure.columnIndices[idx] == col {
                return matrix.values[idx]
            }
        }
        return .zero
    }

    /// Apply previous L rows to update the current row work array.
    private func applyPreviousLRows(
        k: Int,
        symbolic: SymbolicAnalysis,
        rowWork: inout [ComplexPair],
        rowFlag: inout [Int]
    ) {
        let lStart = symbolic.lRowPointers[k]
        let lEnd = symbolic.lRowPointers[k + 1]

        for lIdx in lStart..<lEnd {
            let j = symbolic.lColumnIndices[lIdx]
            let ujjIdx = findUDiagonal(row: j, symbolic: symbolic)
            guard ujjIdx >= 0, uValues[ujjIdx].magnitude > 1e-15 else {
                continue  // Will be caught later
            }

            let lkj = rowWork[j] / uValues[ujjIdx]

            let uRowStart = symbolic.uRowPointers[j]
            let uRowEnd = symbolic.uRowPointers[j + 1]
            for uIdx in uRowStart..<uRowEnd {
                let col = symbolic.uColumnIndices[uIdx]
                if col > j {
                    if rowFlag[col] != k {
                        rowWork[col] = .zero
                        rowFlag[col] = k
                    }
                    rowWork[col] = rowWork[col] - lkj * uValues[uIdx]
                }
            }
        }
    }

    private func findUDiagonal(row: Int, symbolic: SymbolicAnalysis) -> Int {
        let start = symbolic.uRowPointers[row]
        let end = symbolic.uRowPointers[row + 1]
        for idx in start..<end {
            if symbolic.uColumnIndices[idx] == row {
                return idx
            }
        }
        return -1
    }

    /// Solves `A * x = rhs` using the stored complex LU factorization.
    ///
    /// - Throws: ``CompileError/singularMatrix`` if the solver has not been factorized.
    public func solve(rhs: [ComplexPair]) throws -> [ComplexPair] {
        guard factorized else {
            throw CompileError.singularMatrix
        }

        let n = dimension

        if n == 0 {
            return []
        }

        guard let sym = symbolic else {
            throw CompileError.singularMatrix
        }

        // Apply AMD permutation to RHS
        let permutedRHS = sym.permutation.apply(to: rhs)

        // Apply row pivot permutation
        var b = Array(repeating: ComplexPair.zero, count: n)
        for i in 0..<n {
            b[i] = permutedRHS[pivot[i]]
        }

        // Forward substitution: L * y = b
        var y = Array(repeating: ComplexPair.zero, count: n)
        for i in 0..<n {
            var sum = b[i]
            let lStart = sym.lRowPointers[i]
            let lEnd = sym.lRowPointers[i + 1]
            for idx in lStart..<lEnd {
                let j = sym.lColumnIndices[idx]
                sum = sum - lValues[idx] * y[j]
            }
            y[i] = sum
        }

        // Backward substitution: U * x = y
        var x = Array(repeating: ComplexPair.zero, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = y[i]
            var diagValue = ComplexPair.zero

            let uStart = sym.uRowPointers[i]
            let uEnd = sym.uRowPointers[i + 1]
            for idx in uStart..<uEnd {
                let j = sym.uColumnIndices[idx]
                if j == i {
                    diagValue = uValues[idx]
                } else if j > i {
                    sum = sum - uValues[idx] * x[j]
                }
            }

            guard diagValue.magnitude > 1e-15 else {
                throw CompileError.singularMatrix
            }
            x[i] = sum / diagValue
        }

        // Apply inverse AMD permutation
        return sym.permutation.applyInverse(to: x)
    }
}

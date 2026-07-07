/// LU decomposition solver with partial pivoting for complex sparse matrices.
///
/// Uses symbolic analysis to predict fill-in and maintains sparse storage
/// throughout the factorization process. This provides O(nnz) complexity
/// instead of O(n²) for sparse matrices typical of AC circuit analysis.
///
/// **Workspace caching**: Symbolic analysis and all working arrays are
/// computed once for a given sparsity structure and reused across
/// subsequent ``factorize(matrix:)`` calls. This eliminates per-iteration
/// memory allocation in frequency sweeps.
public struct ComplexSparseLUSolver: ComplexLinearSolver {

    private var dimension: Int = 0
    private var symbolic: SymbolicAnalysis?
    private var factorized: Bool = false

    /// Whether to use AMD ordering for fill-reduction.
    public var useAMDOrdering: Bool = true

    // MARK: - Structure Cache

    /// Cached input structure to detect when re-analysis is needed.
    private var cachedStructure: SparseStructure?

    /// Permuted sparsity structure (computed once per structure).
    private var permutedStructure: SparseStructure?

    /// Mapping from original CSR index to permuted CSR index.
    private var permutationMap: [Int] = []

    // MARK: - Permuted Values (refilled each factorize)

    private var permutedValues: [ComplexPair] = []

    // MARK: - Factorization Results

    private var lValues: [ComplexPair] = []
    private var uValues: [ComplexPair] = []
    private var pivot: [Int] = []
    private var useDenseSolve: Bool = false
    private var denseLU: [[ComplexPair]] = []

    /// Per-row overflow storage for L entries outside the symbolic pattern.
    private var lOverflow: [DynamicSparseRow<ComplexPair>] = []
    /// Per-row overflow storage for U entries outside the symbolic pattern.
    private var uOverflow: [DynamicSparseRow<ComplexPair>] = []

    // MARK: - Sparse Factorization Workspace

    private var sparseRowPerm: [Int] = []
    private var sparseRowWork: [ComplexPair] = []
    private var sparseRowFlag: [Int] = []
    private var sparseInSymbolicU: [Bool] = []
    private var sparseInSymbolicL: [Bool] = []

    // MARK: - Solve Workspace

    private var solveTemp: [ComplexPair] = []
    private var solveB: [ComplexPair] = []
    private var solveY: [ComplexPair] = []
    private var solveX: [ComplexPair] = []

    // MARK: - Initialization

    public init() {}

    /// Creates a solver with explicit ordering control.
    ///
    /// - Parameter useAMDOrdering: Whether to compute AMD ordering (default: true).
    public init(useAMDOrdering: Bool) {
        self.useAMDOrdering = useAMDOrdering
    }

    // MARK: - Factorize

    /// Factorizes the complex sparse matrix using LU decomposition with partial pivoting.
    ///
    /// On the first call (or when the sparsity structure changes), performs
    /// symbolic analysis and allocates all working memory. Subsequent calls
    /// with the same structure reuse the cached workspace — zero allocation.
    ///
    /// - Throws: ``CompileError/singularMatrix`` if a zero pivot is encountered.
    public mutating func factorize(matrix: ComplexSparseMatrix) throws {
        factorized = false

        guard matrix.structuralMisses.isEmpty else {
            throw CompileError.incompatibleStructure(
                "Complex sparse matrix received stamps outside the CSR pattern: \(matrix.structuralMisses)"
            )
        }

        let n = matrix.dimension
        dimension = n

        if n == 0 {
            factorized = true
            return
        }

        // Recompute symbolic analysis only when structure changes
        if cachedStructure != matrix.structure {
            let ordering = useAMDOrdering
                ? AMDOrdering.compute(structure: matrix.structure)
                : Permutation.identity(size: n)
            symbolic = SymbolicAnalysis.analyze(structure: matrix.structure, ordering: ordering)
            cachedStructure = matrix.structure

            guard let sym = symbolic else {
                throw CompileError.singularMatrix
            }

            // Build permuted structure and index mapping (one-time cost)
            buildPermutedStructureAndMap(from: matrix.structure, permutation: sym.permutation)

            // Allocate all workspace arrays
            try allocateWorkspace(n: n, symbolic: sym)
        }

        guard let sym = symbolic, let permStruct = permutedStructure else {
            throw CompileError.singularMatrix
        }

        // Remap numeric values through the pre-computed index mapping (O(nnz), zero alloc)
        for i in 0..<matrix.structure.nonZeroCount {
            permutedValues[permutationMap[i]] = matrix.values[i]
        }

        // Factorize using pre-allocated workspace
        if n < 500 {
            try factorizeDense(n: n, permStruct: permStruct)
        } else {
            try factorizeSparse(n: n, permStruct: permStruct, symbolic: sym)
        }

        factorized = true
    }

    // MARK: - One-Time Setup

    /// Builds the permuted sparsity structure and the CSR index mapping.
    private mutating func buildPermutedStructureAndMap(
        from structure: SparseStructure,
        permutation: Permutation
    ) {
        let n = structure.dimension

        struct MappedEntry: Comparable {
            let newRow: Int
            let newCol: Int
            let origIdx: Int

            static func < (lhs: MappedEntry, rhs: MappedEntry) -> Bool {
                if lhs.newRow != rhs.newRow { return lhs.newRow < rhs.newRow }
                return lhs.newCol < rhs.newCol
            }
        }

        var entries: [MappedEntry] = []
        entries.reserveCapacity(structure.nonZeroCount)

        for oldRow in 0..<n {
            let newRow = permutation.forward[oldRow]
            let start = structure.rowPointers[oldRow]
            let end = structure.rowPointers[oldRow + 1]

            for idx in start..<end {
                let oldCol = structure.columnIndices[idx]
                let newCol = permutation.forward[oldCol]
                entries.append(MappedEntry(newRow: newRow, newCol: newCol, origIdx: idx))
            }
        }

        entries.sort()

        var rowPointers = [Int]()
        var columnIndices = [Int]()
        rowPointers.reserveCapacity(n + 1)
        columnIndices.reserveCapacity(entries.count)

        var currentRow = 0
        rowPointers.append(0)

        permutationMap = Array(repeating: 0, count: structure.nonZeroCount)

        for (permIdx, entry) in entries.enumerated() {
            while currentRow < entry.newRow {
                currentRow += 1
                rowPointers.append(columnIndices.count)
            }
            columnIndices.append(entry.newCol)
            permutationMap[entry.origIdx] = permIdx
        }

        while currentRow < n {
            currentRow += 1
            rowPointers.append(columnIndices.count)
        }

        permutedStructure = SparseStructure(
            dimension: n,
            rowPointers: rowPointers,
            columnIndices: columnIndices
        )
    }

    /// Allocates all working arrays for factorization and solve.
    private mutating func allocateWorkspace(n: Int, symbolic sym: SymbolicAnalysis) throws {
        guard let permStruct = permutedStructure else {
            throw CompileError.singularMatrix
        }
        // Permuted values buffer
        permutedValues = Array(repeating: .zero, count: permStruct.nonZeroCount)

        // Pivot (shared between dense and sparse paths)
        pivot = Array(repeating: 0, count: n)

        // Dense path workspace
        denseLU = Array(repeating: Array(repeating: .zero, count: n), count: n)

        // Sparse path workspace
        lValues = Array(repeating: .zero, count: sym.lColumnIndices.count)
        uValues = Array(repeating: .zero, count: sym.uColumnIndices.count)
        lOverflow = Array(repeating: DynamicSparseRow<ComplexPair>(), count: n)
        uOverflow = Array(repeating: DynamicSparseRow<ComplexPair>(), count: n)
        sparseRowPerm = Array(repeating: 0, count: n)
        sparseRowWork = Array(repeating: .zero, count: n)
        sparseRowFlag = Array(repeating: -1, count: n)
        sparseInSymbolicU = Array(repeating: false, count: n)
        sparseInSymbolicL = Array(repeating: false, count: n)

        // Solve workspace
        solveTemp = Array(repeating: .zero, count: n)
        solveB = Array(repeating: .zero, count: n)
        solveY = Array(repeating: .zero, count: n)
        solveX = Array(repeating: .zero, count: n)
    }

    // MARK: - Dense Factorization

    /// Dense factorization for small matrices (optimized for cache locality).
    private mutating func factorizeDense(n: Int, permStruct: SparseStructure) throws {
        // Fill denseLU from permuted sparse values
        for i in 0..<n {
            for j in 0..<n { denseLU[i][j] = .zero }
        }
        for row in 0..<n {
            let start = permStruct.rowPointers[row]
            let end = permStruct.rowPointers[row + 1]
            for idx in start..<end {
                denseLU[row][permStruct.columnIndices[idx]] = permutedValues[idx]
            }
        }

        // Reset pivot to identity
        for i in 0..<n { pivot[i] = i }

        // Gaussian elimination with partial pivoting (by magnitude)
        for k in 0..<n {
            var maxMag = denseLU[k][k].magnitude
            var maxRow = k
            for i in (k + 1)..<n {
                let candidate = denseLU[i][k].magnitude
                if candidate > maxMag {
                    maxMag = candidate
                    maxRow = i
                }
            }

            if maxMag < 1e-15 {
                throw CompileError.singularMatrix
            }

            if maxRow != k {
                denseLU.swapAt(k, maxRow)
                pivot.swapAt(k, maxRow)
            }

            let pivotValue = denseLU[k][k]
            for i in (k + 1)..<n {
                let factor = denseLU[i][k] / pivotValue
                denseLU[i][k] = factor
                for j in (k + 1)..<n {
                    denseLU[i][j] = denseLU[i][j] - factor * denseLU[k][j]
                }
            }
        }

        useDenseSolve = true
    }

    // MARK: - Sparse Factorization

    /// Sparse factorization for large matrices with threshold pivoting.
    private mutating func factorizeSparse(
        n: Int,
        permStruct: SparseStructure,
        symbolic: SymbolicAnalysis
    ) throws {
        let pivotThreshold = 0.1

        // Reset workspace arrays (zero alloc — reuse existing capacity)
        for i in 0..<lValues.count { lValues[i] = .zero }
        for i in 0..<uValues.count { uValues[i] = .zero }
        for i in 0..<n {
            lOverflow[i].clear()
            uOverflow[i].clear()
            pivot[i] = i
            sparseRowPerm[i] = i
            sparseRowWork[i] = .zero
            sparseRowFlag[i] = -1
            sparseInSymbolicU[i] = false
            sparseInSymbolicL[i] = false
        }

        var totalOverflow = 0
        let symbolicNNZ = max(symbolic.lColumnIndices.count + symbolic.uColumnIndices.count, 1)
        useDenseSolve = false

        for k in 0..<n {
            // Clear work array (only marked positions)
            for j in 0..<n where sparseRowFlag[j] == k - 1 {
                sparseRowWork[j] = .zero
            }

            // Load row sparseRowPerm[k] from permuted matrix
            let origRow = sparseRowPerm[k]
            loadPermutedRow(permStruct: permStruct, origRow: origRow, k: k)

            // Apply previous L rows to current row
            applyPreviousLRows(k: k, symbolic: symbolic)

            // --- Threshold Pivoting ---
            let diagMag = sparseRowWork[k].magnitude
            var maxMag = diagMag
            var maxRow = k

            for i in (k + 1)..<n {
                let origRowI = sparseRowPerm[i]
                let valInColK = getPermutedValueInColumn(
                    permStruct: permStruct, origRow: origRowI, col: k
                )
                if valInColK.magnitude > maxMag {
                    maxMag = valInColK.magnitude
                    maxRow = i
                }
            }

            if maxRow != k && diagMag < pivotThreshold * maxMag {
                sparseRowPerm.swapAt(k, maxRow)
                pivot.swapAt(k, maxRow)

                for j in 0..<n where sparseRowFlag[j] == k {
                    sparseRowWork[j] = .zero
                }
                let newOrigRow = sparseRowPerm[k]
                loadPermutedRow(permStruct: permStruct, origRow: newOrigRow, k: k)

                applyPreviousLRows(k: k, symbolic: symbolic)
            }

            // Compute and store L values for column k
            let lStart = symbolic.lRowPointers[k]
            let lEnd = symbolic.lRowPointers[k + 1]

            // Mark symbolic L columns (reuse pre-allocated array)
            for lIdx in lStart..<lEnd {
                sparseInSymbolicL[symbolic.lColumnIndices[lIdx]] = true
            }

            for lIdx in lStart..<lEnd {
                let j = symbolic.lColumnIndices[lIdx]
                let ujjIdx = findUDiagonal(row: j, symbolic: symbolic)
                guard ujjIdx >= 0, uValues[ujjIdx].magnitude > 1e-15 else {
                    for lIdx2 in lStart..<lEnd {
                        sparseInSymbolicL[symbolic.lColumnIndices[lIdx2]] = false
                    }
                    throw CompileError.singularMatrix
                }
                let lkj = sparseRowWork[j] / uValues[ujjIdx]
                lValues[lIdx] = lkj
            }

            // Check for L overflow
            for j in 0..<k where sparseRowFlag[j] == k {
                if !sparseInSymbolicL[j] && sparseRowWork[j].magnitude > 1e-15 {
                    let ujjIdx = findUDiagonal(row: j, symbolic: symbolic)
                    if ujjIdx >= 0 && uValues[ujjIdx].magnitude > 1e-15 {
                        let lkj = sparseRowWork[j] / uValues[ujjIdx]
                        if lkj.magnitude > 1e-15 {
                            lOverflow[k].set(column: j, value: lkj)
                            totalOverflow += 1
                        }
                    }
                }
            }

            // Clear symbolic L markers
            for lIdx in lStart..<lEnd {
                sparseInSymbolicL[symbolic.lColumnIndices[lIdx]] = false
            }

            // Mark columns in the symbolic U pattern for this row
            let uStart = symbolic.uRowPointers[k]
            let uEnd = symbolic.uRowPointers[k + 1]
            for uIdx in uStart..<uEnd {
                sparseInSymbolicU[symbolic.uColumnIndices[uIdx]] = true
            }

            // Store U row — symbolic entries
            for uIdx in uStart..<uEnd {
                let col = symbolic.uColumnIndices[uIdx]
                uValues[uIdx] = sparseRowFlag[col] == k ? sparseRowWork[col] : .zero
            }

            // Detect and store U overflow entries
            for j in k..<n where sparseRowFlag[j] == k {
                if !sparseInSymbolicU[j] && sparseRowWork[j].magnitude > 1e-15 {
                    uOverflow[k].set(column: j, value: sparseRowWork[j])
                    totalOverflow += 1
                }
            }

            // Clear the symbolic U marker for reuse
            for uIdx in uStart..<uEnd {
                sparseInSymbolicU[symbolic.uColumnIndices[uIdx]] = false
            }

            // Early abort: if overflow > 50% of symbolic nnz, fall back to dense
            if k > 0 && k % 50 == 0 {
                let projectedOverflow = totalOverflow * n / k
                if projectedOverflow > symbolicNNZ / 2 {
                    try factorizeDense(n: n, permStruct: permStruct)
                    return
                }
            }

            // Check for zero diagonal
            let diagIdx = findUDiagonal(row: k, symbolic: symbolic)
            if diagIdx < 0 || uValues[diagIdx].magnitude < 1e-15 {
                throw CompileError.singularMatrix
            }
        }
    }

    // MARK: - Sparse Factorization Helpers

    /// Load a row from the permuted matrix into the workspace.
    private mutating func loadPermutedRow(
        permStruct: SparseStructure,
        origRow: Int,
        k: Int
    ) {
        let mStart = permStruct.rowPointers[origRow]
        let mEnd = permStruct.rowPointers[origRow + 1]
        for idx in mStart..<mEnd {
            let col = permStruct.columnIndices[idx]
            sparseRowWork[col] = permutedValues[idx]
            sparseRowFlag[col] = k
        }
    }

    /// Get the value at (origRow, col) from the permuted matrix, or zero if not present.
    private func getPermutedValueInColumn(
        permStruct: SparseStructure,
        origRow: Int,
        col: Int
    ) -> ComplexPair {
        let start = permStruct.rowPointers[origRow]
        let end = permStruct.rowPointers[origRow + 1]
        for idx in start..<end {
            if permStruct.columnIndices[idx] == col {
                return permutedValues[idx]
            }
        }
        return .zero
    }

    /// Apply previous L rows to update the current row work array.
    private mutating func applyPreviousLRows(
        k: Int,
        symbolic: SymbolicAnalysis
    ) {
        for j in 0..<k {
            guard sparseRowFlag[j] == k else { continue }

            let ujjIdx = findUDiagonal(row: j, symbolic: symbolic)
            guard ujjIdx >= 0, uValues[ujjIdx].magnitude > 1e-15 else {
                continue
            }

            let lkj = sparseRowWork[j] / uValues[ujjIdx]

            let uRowStart = symbolic.uRowPointers[j]
            let uRowEnd = symbolic.uRowPointers[j + 1]
            for uIdx in uRowStart..<uRowEnd {
                let col = symbolic.uColumnIndices[uIdx]
                if col > j {
                    if sparseRowFlag[col] != k {
                        sparseRowWork[col] = .zero
                        sparseRowFlag[col] = k
                    }
                    sparseRowWork[col] = sparseRowWork[col] - lkj * uValues[uIdx]
                }
            }

            // Also apply overflow U entries for row j
            uOverflow[j].forEach { col, val in
                if col > j {
                    if sparseRowFlag[col] != k {
                        sparseRowWork[col] = .zero
                        sparseRowFlag[col] = k
                    }
                    sparseRowWork[col] = sparseRowWork[col] - lkj * val
                }
            }
        }
    }

    /// Finds the index of the diagonal element in U for the given row.
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

    // MARK: - Solve (allocating)

    /// Solves `A * x = rhs` using the stored complex LU factorization.
    ///
    /// This method allocates temporary arrays. For zero-allocation solve,
    /// use ``solve(rhs:into:)`` instead.
    ///
    /// - Throws: ``CompileError/singularMatrix`` if the solver has not been factorized.
    public func solve(rhs: [ComplexPair]) throws -> [ComplexPair] {
        guard factorized else {
            throw CompileError.singularMatrix
        }

        let n = dimension
        try validateVectorLength(name: "rhs", actual: rhs.count, expected: n)

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

        if useDenseSolve {
            return try solveDenseAllocating(b: b, permutation: sym.permutation)
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
            lOverflow[i].forEach { j, val in
                sum = sum - val * y[j]
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
            uOverflow[i].forEach { j, val in
                if j > i {
                    sum = sum - val * x[j]
                } else if j == i {
                    diagValue = ComplexPair(real: diagValue.real + val.real, imag: diagValue.imag + val.imag)
                }
            }

            guard diagValue.magnitude > 1e-15 else {
                throw CompileError.singularMatrix
            }
            x[i] = sum / diagValue
        }

        return sym.permutation.applyInverse(to: x)
    }

    /// Dense solve (allocating variant).
    private func solveDenseAllocating(b: [ComplexPair], permutation: Permutation) throws -> [ComplexPair] {
        let n = dimension

        var y = Array(repeating: ComplexPair.zero, count: n)
        for i in 0..<n {
            var sum = b[i]
            for j in 0..<i {
                sum = sum - denseLU[i][j] * y[j]
            }
            y[i] = sum
        }

        var x = Array(repeating: ComplexPair.zero, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = y[i]
            for j in (i + 1)..<n {
                sum = sum - denseLU[i][j] * x[j]
            }
            let diagValue = denseLU[i][i]
            guard diagValue.magnitude > 1e-15 else {
                throw CompileError.singularMatrix
            }
            x[i] = sum / diagValue
        }

        return permutation.applyInverse(to: x)
    }

    // MARK: - Solve (zero-allocation)

    /// Solves `A * x = rhs` into a pre-allocated buffer using workspace arrays.
    ///
    /// No memory allocation occurs during this method.
    public mutating func solve(rhs: [ComplexPair], into result: inout [ComplexPair]) throws {
        guard factorized else {
            throw CompileError.singularMatrix
        }

        let n = dimension
        try validateVectorLength(name: "rhs", actual: rhs.count, expected: n)
        try validateVectorLength(name: "result", actual: result.count, expected: n)

        if n == 0 {
            return
        }

        guard let sym = symbolic else {
            throw CompileError.singularMatrix
        }

        // 1. Apply AMD permutation: rhs → solveTemp
        sym.permutation.apply(from: rhs, into: &solveTemp)

        // 2. Apply pivot permutation: solveTemp → solveB
        for i in 0..<n {
            solveB[i] = solveTemp[pivot[i]]
        }

        if useDenseSolve {
            // Dense forward substitution: L * y = b
            for i in 0..<n {
                var sum = solveB[i]
                for j in 0..<i {
                    sum = sum - denseLU[i][j] * solveY[j]
                }
                solveY[i] = sum
            }

            // Dense backward substitution: U * x = y
            for i in stride(from: n - 1, through: 0, by: -1) {
                var sum = solveY[i]
                for j in (i + 1)..<n {
                    sum = sum - denseLU[i][j] * solveX[j]
                }
                let diagValue = denseLU[i][i]
                guard diagValue.magnitude > 1e-15 else {
                    throw CompileError.singularMatrix
                }
                solveX[i] = sum / diagValue
            }
        } else {
            // Sparse forward substitution: L * y = b
            for i in 0..<n {
                var sum = solveB[i]
                let lStart = sym.lRowPointers[i]
                let lEnd = sym.lRowPointers[i + 1]
                for idx in lStart..<lEnd {
                    let j = sym.lColumnIndices[idx]
                    sum = sum - lValues[idx] * solveY[j]
                }
                lOverflow[i].forEach { j, val in
                    sum = sum - val * solveY[j]
                }
                solveY[i] = sum
            }

            // Sparse backward substitution: U * x = y
            for i in stride(from: n - 1, through: 0, by: -1) {
                var sum = solveY[i]
                var diagValue = ComplexPair.zero

                let uStart = sym.uRowPointers[i]
                let uEnd = sym.uRowPointers[i + 1]
                for idx in uStart..<uEnd {
                    let j = sym.uColumnIndices[idx]
                    if j == i {
                        diagValue = uValues[idx]
                    } else if j > i {
                        sum = sum - uValues[idx] * solveX[j]
                    }
                }
                uOverflow[i].forEach { j, val in
                    if j > i {
                        sum = sum - val * solveX[j]
                    } else if j == i {
                        diagValue = ComplexPair(real: diagValue.real + val.real, imag: diagValue.imag + val.imag)
                    }
                }

                guard diagValue.magnitude > 1e-15 else {
                    throw CompileError.singularMatrix
                }
                solveX[i] = sum / diagValue
            }
        }

        // 5. Apply inverse AMD permutation: solveX → result
        sym.permutation.applyInverse(from: solveX, into: &result)
    }

    private func validateVectorLength(name: String, actual: Int, expected: Int) throws {
        guard actual == expected else {
            throw CompileError.vectorDimensionMismatch(vector: name, expected: expected, actual: actual)
        }
    }
}

import Accelerate

/// LU decomposition solver with partial pivoting for real sparse matrices.
///
/// Uses symbolic analysis to predict fill-in and maintains sparse storage
/// throughout the factorization process. This provides O(nnz) complexity
/// instead of O(n²) for sparse matrices typical of circuit simulation.
///
/// **Workspace caching**: Symbolic analysis and all working arrays are
/// computed once for a given sparsity structure and reused across
/// subsequent ``factorize(matrix:)`` calls. This eliminates per-iteration
/// memory allocation in Newton-Raphson loops.
public struct SparseLUSolver: LinearSolver {

    private var dimension: Int = 0
    private var symbolic: SymbolicAnalysis?
    private var factorized: Bool = false

    /// Whether to use AMD ordering for fill-reduction.
    /// Set to false to use natural ordering (for testing or pre-ordered matrices).
    public var useAMDOrdering: Bool = true

    // MARK: - Structure Cache

    /// Cached input structure to detect when re-analysis is needed.
    private var cachedStructure: SparseStructure?

    /// Permuted sparsity structure (computed once per structure).
    private var permutedStructure: SparseStructure?

    /// Mapping from original CSR index to permuted CSR index.
    /// `permutedValues[permutationMap[i]] = matrix.values[i]`
    private var permutationMap: [Int] = []

    // MARK: - Permuted Values (refilled each factorize)

    private var permutedValues: [Double] = []

    // MARK: - Factorization Results

    private var lValues: [Double] = []
    private var uValues: [Double] = []
    private var pivot: [Int] = []
    private var useDenseSolve: Bool = false
    /// Flat column-major dense LU storage for LAPACK (n × n).
    private var denseLU: [Double] = []
    /// LAPACK pivot indices from dgetrf_ (1-based).
    private var lapackPivot: [__CLPK_integer] = []

    /// Per-row overflow storage for L entries outside the symbolic pattern.
    private var lOverflow: [DynamicSparseRow<Double>] = []
    /// Per-row overflow storage for U entries outside the symbolic pattern.
    private var uOverflow: [DynamicSparseRow<Double>] = []

    // MARK: - Sparse Factorization Workspace

    private var sparseRowPerm: [Int] = []
    private var sparseRowWork: [Double] = []
    private var sparseRowFlag: [Int] = []
    private var sparseInSymbolicU: [Bool] = []
    private var sparseInSymbolicL: [Bool] = []

    // MARK: - Solve Workspace

    private var solveTemp: [Double] = []
    private var solveB: [Double] = []
    private var solveY: [Double] = []
    private var solveX: [Double] = []

    // MARK: - Initialization

    public init() {}

    /// Creates a solver with explicit ordering control.
    ///
    /// - Parameter useAMDOrdering: Whether to compute AMD ordering (default: true).
    public init(useAMDOrdering: Bool) {
        self.useAMDOrdering = useAMDOrdering
    }

    // MARK: - Factorize

    /// Factorizes the sparse matrix using LU decomposition with partial pivoting.
    ///
    /// On the first call (or when the sparsity structure changes), performs
    /// symbolic analysis and allocates all working memory. Subsequent calls
    /// with the same structure reuse the cached workspace — zero allocation.
    ///
    /// - Throws: ``CompileError/singularMatrix`` if a zero pivot is encountered.
    public mutating func factorize(matrix: SparseMatrix) throws {
        guard matrix.structuralMisses.isEmpty else {
            throw CompileError.incompatibleStructure(
                "Sparse matrix received stamps outside the CSR pattern: \(matrix.structuralMisses)"
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
            allocateWorkspace(n: n, symbolic: sym)
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
    ///
    /// Given original structure and permutation, computes:
    /// - `permutedStructure`: the CSR structure after row/column reordering
    /// - `permutationMap[origIdx]`: the permuted CSR index for each original CSR index
    private mutating func buildPermutedStructureAndMap(
        from structure: SparseStructure,
        permutation: Permutation
    ) {
        let n = structure.dimension

        // Collect permuted entries with original index tracking
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

        // Build permuted CSR structure
        var rowPointers = [Int]()
        var columnIndices = [Int]()
        rowPointers.reserveCapacity(n + 1)
        columnIndices.reserveCapacity(entries.count)

        var currentRow = 0
        rowPointers.append(0)

        // Also build the mapping
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
    ///
    /// Called once per structure change. All subsequent factorize/solve
    /// calls reuse these arrays with zero allocation.
    private mutating func allocateWorkspace(n: Int, symbolic sym: SymbolicAnalysis) {
        // Permuted values buffer
        permutedValues = Array(repeating: 0.0, count: permutedStructure!.nonZeroCount)

        // Pivot (shared between dense and sparse paths)
        pivot = Array(repeating: 0, count: n)

        // Dense path workspace (flat column-major for LAPACK)
        denseLU = Array(repeating: 0.0, count: n * n)
        lapackPivot = Array(repeating: 0, count: n)

        // Sparse path workspace
        lValues = Array(repeating: 0.0, count: sym.lColumnIndices.count)
        uValues = Array(repeating: 0.0, count: sym.uColumnIndices.count)
        lOverflow = Array(repeating: DynamicSparseRow<Double>(), count: n)
        uOverflow = Array(repeating: DynamicSparseRow<Double>(), count: n)
        sparseRowPerm = Array(repeating: 0, count: n)
        sparseRowWork = Array(repeating: 0.0, count: n)
        sparseRowFlag = Array(repeating: -1, count: n)
        sparseInSymbolicU = Array(repeating: false, count: n)
        sparseInSymbolicL = Array(repeating: false, count: n)

        // Solve workspace
        solveTemp = Array(repeating: 0.0, count: n)
        solveB = Array(repeating: 0.0, count: n)
        solveY = Array(repeating: 0.0, count: n)
        solveX = Array(repeating: 0.0, count: n)
    }

    // MARK: - Dense Factorization

    /// Dense factorization for small matrices using LAPACK dgetrf_.
    ///
    /// Fills the flat column-major `denseLU` workspace from permuted CSR values,
    /// then calls LAPACK's optimized LU factorization with partial pivoting.
    private mutating func factorizeDense(n: Int, permStruct: SparseStructure) throws {
        // Fill flat column-major denseLU from permuted sparse values (vDSP-accelerated zeroing)
        denseLU.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress {
                vDSP_vclrD(base, 1, vDSP_Length(buf.count))
            }
        }
        for row in 0..<n {
            let start = permStruct.rowPointers[row]
            let end = permStruct.rowPointers[row + 1]
            for idx in start..<end {
                let col = permStruct.columnIndices[idx]
                // Column-major: element (row, col) is at index col * n + row
                denseLU[col * n + row] = permutedValues[idx]
            }
        }

        // LAPACK LU factorization with partial pivoting
        var m = __CLPK_integer(n)
        var nn = __CLPK_integer(n)
        var lda = __CLPK_integer(n)
        var info: __CLPK_integer = 0

        dgetrf_(&m, &nn, &denseLU, &lda, &lapackPivot, &info)

        guard info == 0 else {
            throw CompileError.singularMatrix
        }

        useDenseSolve = true
    }

    // MARK: - Sparse Factorization

    /// Sparse factorization for large matrices with threshold pivoting.
    ///
    /// Uses pre-allocated workspace arrays. No memory allocation occurs
    /// during this method.
    private mutating func factorizeSparse(
        n: Int,
        permStruct: SparseStructure,
        symbolic: SymbolicAnalysis
    ) throws {
        let pivotThreshold = 0.1

        // Reset workspace arrays using vDSP for SIMD-accelerated zeroing
        lValues.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress {
                vDSP_vclrD(base, 1, vDSP_Length(buf.count))
            }
        }
        uValues.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress {
                vDSP_vclrD(base, 1, vDSP_Length(buf.count))
            }
        }
        sparseRowWork.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress {
                vDSP_vclrD(base, 1, vDSP_Length(buf.count))
            }
        }
        for i in 0..<n {
            lOverflow[i].clear()
            uOverflow[i].clear()
            pivot[i] = i
            sparseRowPerm[i] = i
            sparseRowFlag[i] = -1
            sparseInSymbolicU[i] = false
            sparseInSymbolicL[i] = false
        }

        var totalOverflow = 0
        let symbolicNNZ = max(symbolic.lColumnIndices.count + symbolic.uColumnIndices.count, 1)
        useDenseSolve = false

        // Process each elimination step
        for k in 0..<n {
            // Clear work array (only marked positions)
            for j in 0..<n where sparseRowFlag[j] == k - 1 {
                sparseRowWork[j] = 0.0
            }

            // Load row sparseRowPerm[k] from permuted matrix
            let origRow = sparseRowPerm[k]
            loadPermutedRow(permStruct: permStruct, origRow: origRow, k: k)

            // Apply previous L rows to current row
            applyPreviousLRows(k: k, symbolic: symbolic)

            // --- Threshold Pivoting ---
            let diagVal = abs(sparseRowWork[k])
            var maxVal = diagVal
            var maxRow = k

            for i in (k + 1)..<n {
                let origRowI = sparseRowPerm[i]
                let valInColK = getPermutedValueInColumn(
                    permStruct: permStruct, origRow: origRowI, col: k
                )
                if abs(valInColK) > maxVal {
                    maxVal = abs(valInColK)
                    maxRow = i
                }
            }

            // Swap rows if diagonal is too small compared to maximum
            if maxRow != k && diagVal < pivotThreshold * maxVal {
                sparseRowPerm.swapAt(k, maxRow)
                pivot.swapAt(k, maxRow)

                // Reload row k with the new assignment
                for j in 0..<n where sparseRowFlag[j] == k {
                    sparseRowWork[j] = 0.0
                }
                let newOrigRow = sparseRowPerm[k]
                loadPermutedRow(permStruct: permStruct, origRow: newOrigRow, k: k)

                // Re-apply previous L rows
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
                guard ujjIdx >= 0, abs(uValues[ujjIdx]) > 1e-15 else {
                    // Clear markers before throwing
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
                if !sparseInSymbolicL[j] && abs(sparseRowWork[j]) > 1e-15 {
                    let ujjIdx = findUDiagonal(row: j, symbolic: symbolic)
                    if ujjIdx >= 0 && abs(uValues[ujjIdx]) > 1e-15 {
                        let lkj = sparseRowWork[j] / uValues[ujjIdx]
                        if abs(lkj) > 1e-15 {
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
                uValues[uIdx] = sparseRowFlag[col] == k ? sparseRowWork[col] : 0.0
            }

            // Detect and store U overflow entries
            for j in k..<n where sparseRowFlag[j] == k {
                if !sparseInSymbolicU[j] && abs(sparseRowWork[j]) > 1e-15 {
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
                    try factorizeDense(n: n, permStruct: permutedStructure!)
                    return
                }
            }

            // Check for zero diagonal
            let diagIdx = findUDiagonal(row: k, symbolic: symbolic)
            if diagIdx < 0 || abs(uValues[diagIdx]) < 1e-15 {
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

    /// Get the value at (origRow, col) from the permuted matrix, or 0 if not present.
    private func getPermutedValueInColumn(
        permStruct: SparseStructure,
        origRow: Int,
        col: Int
    ) -> Double {
        let start = permStruct.rowPointers[origRow]
        let end = permStruct.rowPointers[origRow + 1]
        for idx in start..<end {
            if permStruct.columnIndices[idx] == col {
                return permutedValues[idx]
            }
        }
        return 0.0
    }

    /// Apply previous L rows to update the current row work array.
    ///
    /// Iterates ALL active columns `j < k` (not only symbolic L columns)
    /// in ascending order to ensure complete row elimination.
    private mutating func applyPreviousLRows(
        k: Int,
        symbolic: SymbolicAnalysis
    ) {
        for j in 0..<k {
            guard sparseRowFlag[j] == k else { continue }

            let ujjIdx = findUDiagonal(row: j, symbolic: symbolic)
            guard ujjIdx >= 0, abs(uValues[ujjIdx]) > 1e-15 else {
                continue
            }

            let lkj = sparseRowWork[j] / uValues[ujjIdx]

            let uRowStart = symbolic.uRowPointers[j]
            let uRowEnd = symbolic.uRowPointers[j + 1]
            for uIdx in uRowStart..<uRowEnd {
                let col = symbolic.uColumnIndices[uIdx]
                if col > j {
                    if sparseRowFlag[col] != k {
                        sparseRowWork[col] = 0.0
                        sparseRowFlag[col] = k
                    }
                    sparseRowWork[col] -= lkj * uValues[uIdx]
                }
            }

            // Also apply overflow U entries for row j
            uOverflow[j].forEach { col, val in
                if col > j {
                    if sparseRowFlag[col] != k {
                        sparseRowWork[col] = 0.0
                        sparseRowFlag[col] = k
                    }
                    sparseRowWork[col] -= lkj * val
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

    /// Solves `A * x = rhs` using the stored LU factorization.
    ///
    /// This method allocates temporary arrays. For zero-allocation solve,
    /// use ``solve(rhs:into:)`` instead.
    ///
    /// - Throws: ``CompileError/singularMatrix`` if the solver has not been factorized.
    public func solve(rhs: [Double]) throws -> [Double] {
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

        if useDenseSolve {
            // LAPACK dgetrs_ handles pivoting internally via lapackPivot
            return try solveDenseAllocating(b: permutedRHS, permutation: sym.permutation)
        }

        // Apply row pivot permutation: b = P * permutedRHS (sparse path only)
        var b = Array(repeating: 0.0, count: n)
        for i in 0..<n {
            b[i] = permutedRHS[pivot[i]]
        }

        // Forward substitution: L * y = b
        var y = Array(repeating: 0.0, count: n)
        for i in 0..<n {
            var sum = b[i]
            let lStart = sym.lRowPointers[i]
            let lEnd = sym.lRowPointers[i + 1]
            for idx in lStart..<lEnd {
                let j = sym.lColumnIndices[idx]
                sum -= lValues[idx] * y[j]
            }
            lOverflow[i].forEach { j, val in
                sum -= val * y[j]
            }
            y[i] = sum
        }

        // Backward substitution: U * x = y
        var x = Array(repeating: 0.0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = y[i]
            var diagValue = 0.0

            let uStart = sym.uRowPointers[i]
            let uEnd = sym.uRowPointers[i + 1]
            for idx in uStart..<uEnd {
                let j = sym.uColumnIndices[idx]
                if j == i {
                    diagValue = uValues[idx]
                } else if j > i {
                    sum -= uValues[idx] * x[j]
                }
            }
            uOverflow[i].forEach { j, val in
                if j > i {
                    sum -= val * x[j]
                } else if j == i {
                    diagValue += val
                }
            }

            guard abs(diagValue) > 1e-15 else {
                throw CompileError.singularMatrix
            }
            x[i] = sum / diagValue
        }

        return sym.permutation.applyInverse(to: x)
    }

    /// Dense solve using LAPACK dgetrs_ (allocating variant).
    private func solveDenseAllocating(b: [Double], permutation: Permutation) throws -> [Double] {
        let n = dimension
        var x = b  // dgetrs_ overwrites the RHS in-place

        var nn = __CLPK_integer(n)
        var nrhs: __CLPK_integer = 1
        var lda = __CLPK_integer(n)
        var ldb = __CLPK_integer(n)
        var info: __CLPK_integer = 0
        var trans: CChar = 78  // 'N' (no transpose)

        // Need a mutable copy of denseLU and lapackPivot for LAPACK
        var lu = denseLU
        var ipiv = lapackPivot

        dgetrs_(&trans, &nn, &nrhs, &lu, &lda, &ipiv, &x, &ldb, &info)

        guard info == 0 else {
            throw CompileError.singularMatrix
        }

        return permutation.applyInverse(to: x)
    }

    // MARK: - Solve (zero-allocation)

    /// Solves `A * x = rhs` into a pre-allocated buffer using workspace arrays.
    ///
    /// No memory allocation occurs during this method. All intermediate
    /// buffers (`solveTemp`, `solveB`, `solveY`, `solveX`) are pre-allocated
    /// during ``factorize(matrix:)``.
    ///
    /// - Parameters:
    ///   - rhs: Right-hand-side vector.
    ///   - result: Pre-allocated output buffer for the solution vector.
    /// - Throws: ``CompileError/singularMatrix`` if not factorized or singular.
    public mutating func solve(rhs: [Double], into result: inout [Double]) throws {
        guard factorized else {
            throw CompileError.singularMatrix
        }

        let n = dimension

        if n == 0 {
            return
        }

        guard let sym = symbolic else {
            throw CompileError.singularMatrix
        }

        // 1. Apply AMD permutation: rhs → solveTemp
        sym.permutation.apply(from: rhs, into: &solveTemp)

        if useDenseSolve {
            // LAPACK dgetrs_ handles pivoting internally via lapackPivot.
            // Copy AMD-permuted RHS to solveY (dgetrs_ overwrites in-place).
            for i in 0..<n { solveY[i] = solveTemp[i] }

            var nn = __CLPK_integer(n)
            var nrhs: __CLPK_integer = 1
            var lda = __CLPK_integer(n)
            var ldb = __CLPK_integer(n)
            var info: __CLPK_integer = 0
            var trans: CChar = 78  // 'N'

            dgetrs_(&trans, &nn, &nrhs, &denseLU, &lda, &lapackPivot, &solveY, &ldb, &info)

            guard info == 0 else {
                throw CompileError.singularMatrix
            }

            // solveY now contains the solution; copy to solveX for inverse permutation
            for i in 0..<n { solveX[i] = solveY[i] }
        } else {
            // 2. Apply pivot permutation: solveTemp → solveB (sparse path only)
            for i in 0..<n {
                solveB[i] = solveTemp[pivot[i]]
            }

            // Sparse forward substitution: L * y = b
            for i in 0..<n {
                var sum = solveB[i]
                let lStart = sym.lRowPointers[i]
                let lEnd = sym.lRowPointers[i + 1]
                for idx in lStart..<lEnd {
                    let j = sym.lColumnIndices[idx]
                    sum -= lValues[idx] * solveY[j]
                }
                lOverflow[i].forEach { j, val in
                    sum -= val * solveY[j]
                }
                solveY[i] = sum
            }

            // Sparse backward substitution: U * x = y
            for i in stride(from: n - 1, through: 0, by: -1) {
                var sum = solveY[i]
                var diagValue = 0.0

                let uStart = sym.uRowPointers[i]
                let uEnd = sym.uRowPointers[i + 1]
                for idx in uStart..<uEnd {
                    let j = sym.uColumnIndices[idx]
                    if j == i {
                        diagValue = uValues[idx]
                    } else if j > i {
                        sum -= uValues[idx] * solveX[j]
                    }
                }
                uOverflow[i].forEach { j, val in
                    if j > i {
                        sum -= val * solveX[j]
                    } else if j == i {
                        diagValue += val
                    }
                }

                guard abs(diagValue) > 1e-15 else {
                    throw CompileError.singularMatrix
                }
                solveX[i] = sum / diagValue
            }
        }

        // 5. Apply inverse AMD permutation: solveX → result
        sym.permutation.applyInverse(from: solveX, into: &result)
    }
}

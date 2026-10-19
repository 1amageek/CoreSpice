/// Advisory structural LU closure without numeric row pivots or cancellation of entries.
/// This pattern must never authorize numeric factor storage under row pivoting.
public struct SymbolicAnalysis: Sendable {
    /// The fill-reducing permutation applied before factorization.
    public let permutation: Permutation

    /// An advisory dependency forest from no-pivot structural elimination.
    ///
    /// `eliminationTree[i]` is the parent of node `i` in the tree, or `-1` if `i` is a root.
    /// It does not certify independent numeric work for an unsymmetric matrix.
    public let eliminationTree: [Int]

    /// Number of additional non-zero entries introduced by factorization.
    public let fillInCount: Int

    /// The sparsity pattern of the combined L+U factors including fill-in.
    public let factorizationStructure: SparseStructure

    /// Row pointers into the L factor (lower triangular).
    public let lRowPointers: [Int]

    /// Column indices for the L factor.
    public let lColumnIndices: [Int]

    /// Row pointers into the U factor (upper triangular).
    public let uRowPointers: [Int]

    /// Column indices for the U factor.
    public let uColumnIndices: [Int]

    private let storageLease: (any Sendable)?

    public static func analyze(
        structure: SparseStructure,
        control: (any LinearSolverExecutionControlling)? = nil
    ) throws -> SymbolicAnalysis {
        let permutation = try AMDOrdering.compute(structure: structure, control: control)
        return try analyze(structure: structure, ordering: permutation, control: control)
    }

    /// Computes complete unsymmetric structural closure for the supplied ordering.
    /// Missing diagonals are included; numeric row pivoting can introduce other entries.
    public static func analyze(
        structure: SparseStructure,
        ordering permutation: Permutation,
        control: (any LinearSolverExecutionControlling)? = nil
    ) throws -> SymbolicAnalysis {
        try control?.checkpoint(workUnits: 1)
        let n = structure.dimension
        guard permutation.forward.count == n, permutation.inverse.count == n else {
            throw SparseOrderingError.invalidPermutation
        }
        for index in 0..<n {
            try control?.checkpoint(workUnits: 1)
            let mapped = permutation.forward[index]
            guard mapped >= 0, mapped < n, permutation.inverse[mapped] == index else {
                throw SparseOrderingError.invalidPermutation
            }
        }
        var rows = try SparseOrderingGraph(dimension: n, control: control)
        var columns = try SparseOrderingGraph(dimension: n, control: control)
        for row in 0..<n {
            try control?.checkpoint(workUnits: 1)
            let newRow = permutation.forward[row]
            try rows.insert(row: newRow, column: newRow)
            try columns.insert(row: newRow, column: newRow)
            for index in structure.rowPointers[row]..<structure.rowPointers[row + 1] {
                let column = permutation.forward[structure.columnIndices[index]]
                try rows.insert(row: newRow, column: column)
                try columns.insert(row: column, column: newRow)
            }
        }
        let scratchLease = try SparseOrderingSupport.reserve(
            try SparseOrderingSupport.multiply(n, 4), control: control)
        var lowerRows: [Int] = []
        var upperColumns: [Int] = []
        lowerRows.reserveCapacity(n)
        upperColumns.reserveCapacity(n)
        // A pivot introduces every outer-product position L(i,k) * U(k,j),
        // including newly discovered lower entries used by later pivots.
        var tree = Array(repeating: -1, count: n)
        for pivot in 0..<n {
            try control?.checkpoint(workUnits: 1)
            lowerRows.removeAll(keepingCapacity: true)
            upperColumns.removeAll(keepingCapacity: true)
            for row in columns.rows[pivot] {
                try control?.checkpoint(workUnits: 1)
                if row > pivot {
                    lowerRows.append(row)
                    if tree[pivot] == -1 || row < tree[pivot] { tree[pivot] = row }
                }
            }
            for column in rows.rows[pivot] {
                try control?.checkpoint(workUnits: 1)
                if column > pivot { upperColumns.append(column) }
            }
            for row in lowerRows {
                for column in upperColumns {
                    try rows.insert(row: row, column: column)
                    try columns.insert(row: column, column: row)
                }
            }
        }
        var count = 0
        for row in 0..<n {
            try control?.checkpoint(workUnits: 1)
            count = try SparseOrderingSupport.add(count, rows.rows[row].count)
        }
        let pointerCount = try SparseOrderingSupport.add(n, 1)
        // Combined CSR and separate L/U share no mutable buffer. Count each payload,
        // including the dependency forest created above, before allocating output.
        let outputCount = try SparseOrderingSupport.add(
            try SparseOrderingSupport.add(try SparseOrderingSupport.multiply(count, 3), n),
            try SparseOrderingSupport.multiply(pointerCount, 3))
        let outputLease = try SparseOrderingSupport.reserve(outputCount, control: control)
        var rowPointers: [Int] = []
        var combined: [Int] = []
        var lPointers: [Int] = []
        var lColumns: [Int] = []
        var uPointers: [Int] = []
        var uColumns: [Int] = []
        rowPointers.reserveCapacity(pointerCount)
        lPointers.reserveCapacity(pointerCount)
        uPointers.reserveCapacity(pointerCount)
        combined.reserveCapacity(count)
        // Reserve exact upper bounds for both arrays. The admission includes this
        // explicit capacity slack rather than counting only occupied factor entries.
        lColumns.reserveCapacity(count)
        uColumns.reserveCapacity(count)
        var sorted: [Int] = []
        sorted.reserveCapacity(n)
        for row in 0..<n {
            try control?.checkpoint(workUnits: 1)
            rowPointers.append(combined.count)
            lPointers.append(lColumns.count)
            uPointers.append(uColumns.count)
            sorted.removeAll(keepingCapacity: true)
            for column in rows.rows[row] {
                try control?.checkpoint(workUnits: 1)
                sorted.append(column)
            }
            try SparseOrderingSupport.sort(&sorted, control: control)
            for column in sorted {
                try control?.checkpoint(workUnits: 1)
                combined.append(column)
                if column < row { lColumns.append(column) } else { uColumns.append(column) }
            }
        }
        rowPointers.append(combined.count)
        lPointers.append(lColumns.count)
        uPointers.append(uColumns.count)
        withExtendedLifetime((rows, columns, scratchLease)) {}
        return SymbolicAnalysis(
            permutation: permutation,
            eliminationTree: tree,
            fillInCount: count - structure.nonZeroCount,
            factorizationStructure: SparseStructure(
                uncheckedDimension: n, rowPointers: rowPointers, columnIndices: combined),
            lRowPointers: lPointers,
            lColumnIndices: lColumns,
            uRowPointers: uPointers,
            uColumnIndices: uColumns,
            storageLease: outputLease
        )
    }
}
// MARK: - Elimination Tree Utilities

extension SymbolicAnalysis {

    /// Returns the depth of each node in the elimination tree.
    ///
    /// Useful for scheduling parallel factorization.
    public func treeDepths() -> [Int] {
        let n = eliminationTree.count
        var depths = Array(repeating: 0, count: n)

        for i in 0..<n {
            var depth = 0
            var node = i
            while eliminationTree[node] != -1 {
                depth += 1
                node = eliminationTree[node]
            }
            depths[i] = depth
        }

        return depths
    }

    /// Returns nodes grouped by their depth in the elimination tree.
    ///
    /// Nodes at the same depth can potentially be factorized in parallel.
    public func levelSets() -> [[Int]] {
        let depths = treeDepths()
        guard let maxDepth = depths.max() else { return [] }

        var levels = Array(repeating: [Int](), count: maxDepth + 1)
        for (node, depth) in depths.enumerated() {
            levels[depth].append(node)
        }

        return levels
    }

    /// Returns the children of each node in the elimination tree.
    public func treeChildren() -> [[Int]] {
        let n = eliminationTree.count
        var children = Array(repeating: [Int](), count: n)

        for (node, parent) in eliminationTree.enumerated() {
            if parent >= 0 {
                children[parent].append(node)
            }
        }

        return children
    }
}

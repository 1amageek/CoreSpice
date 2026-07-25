/// Result of a symbolic analysis of a sparse matrix structure.
///
/// Symbolic analysis performs a dry-run of the factorization process,
/// predicting fill-in positions without computing actual numeric values.
/// This enables:
/// - Pre-allocation of memory for L and U factors
/// - Detection of optimal memory layouts
/// - Parallelization via the elimination tree
public struct SymbolicAnalysis: Sendable {

    /// The fill-reducing permutation applied before factorization.
    public let permutation: Permutation

    /// The elimination tree representing dependencies during factorization.
    ///
    /// `eliminationTree[i]` is the parent of node `i` in the tree, or `-1` if `i` is a root.
    /// The elimination tree enables parallel factorization by identifying independent subtrees.
    public let eliminationTree: [Int]

    /// Number of additional non-zero entries introduced by factorization.
    public let fillInCount: Int

    /// The sparsity pattern of the combined L+U factors including fill-in.
    public let factorizationStructure: SparseStructure

    /// Row pointers into the L factor (lower triangular).
    /// Used for efficient sparse forward/backward substitution.
    public let lRowPointers: [Int]

    /// Column indices for the L factor.
    public let lColumnIndices: [Int]

    /// Row pointers into the U factor (upper triangular).
    public let uRowPointers: [Int]

    /// Column indices for the U factor.
    public let uColumnIndices: [Int]

    /// Analyzes the given sparsity pattern for fill-in using symbolic elimination.
    ///
    /// This method:
    /// 1. Computes an AMD fill-reducing ordering
    /// 2. Performs symbolic Gaussian elimination to predict fill-in
    /// 3. Builds the elimination tree for potential parallelization
    ///
    /// - Parameter structure: The original sparsity pattern.
    /// - Returns: The analysis result with fill-in prediction.
    public static func analyze(structure: SparseStructure) -> SymbolicAnalysis {
        // Compute fill-reducing ordering
        let permutation = AMDOrdering.compute(structure: structure)
        return analyze(structure: structure, ordering: permutation)
    }

    /// Analyzes the given sparsity pattern using a provided ordering.
    ///
    /// - Parameters:
    ///   - structure: The original sparsity pattern.
    ///   - ordering: The permutation to apply before factorization.
    /// - Returns: The analysis result with fill-in prediction.
    public static func analyze(structure: SparseStructure, ordering perm: Permutation) -> SymbolicAnalysis {
        let n = structure.dimension

        if n == 0 {
            return SymbolicAnalysis(
                permutation: perm,
                eliminationTree: [],
                fillInCount: 0,
                factorizationStructure: structure,
                lRowPointers: [0],
                lColumnIndices: [],
                uRowPointers: [0],
                uColumnIndices: []
            )
        }

        // Build reordered adjacency structure
        var reorderedAdj = buildReorderedAdjacency(structure: structure, permutation: perm)

        // Ensure diagonal exists
        for i in 0..<n {
            reorderedAdj[i].insert(i)
        }

        // Perform symbolic elimination and build elimination tree
        var eliminationTree = Array(repeating: -1, count: n)
        var lSets = Array(repeating: Set<Int>(), count: n)  // L entries by row (column indices < row)
        var uSets = Array(repeating: Set<Int>(), count: n)  // U entries by row (column indices >= row)

        for k in 0..<n {
            // Initialize L_k with original entries below diagonal
            // Initialize U_k with original entries at or above diagonal
            for j in reorderedAdj[k] {
                if j < k {
                    lSets[k].insert(j)
                } else {
                    uSets[k].insert(j)
                }
            }

            // Process fill-in from previous columns
            // For each j < k where L(k,j) != 0, merge U(j, j+1:) into U(k, :)
            for j in lSets[k].sorted() {
                // Add fill-in: columns in U_j that are > k go into U_k
                for col in uSets[j] where col > k {
                    uSets[k].insert(col)
                }

                // Update elimination tree: first non-zero in U_j below diagonal determines parent
                if eliminationTree[j] == -1 {
                    eliminationTree[j] = k
                }
            }

            // For U(k, col) with col > k, we need to add L(col, k)
            for col in uSets[k] where col > k {
                lSets[col].insert(k)
            }
        }

        // Count fill-in
        let originalNNZ = structure.nonZeroCount
        var totalLNNZ = 0
        var totalUNNZ = 0
        for k in 0..<n {
            totalLNNZ += lSets[k].count
            totalUNNZ += uSets[k].count
        }

        // Build CSR structures for L and U
        var lRowPointers = [Int]()
        var lColumnIndices = [Int]()
        var uRowPointers = [Int]()
        var uColumnIndices = [Int]()

        lRowPointers.reserveCapacity(n + 1)
        uRowPointers.reserveCapacity(n + 1)
        lColumnIndices.reserveCapacity(totalLNNZ)
        uColumnIndices.reserveCapacity(totalUNNZ)

        var lOffset = 0
        var uOffset = 0

        for k in 0..<n {
            lRowPointers.append(lOffset)
            let lCols = lSets[k].sorted()
            lColumnIndices.append(contentsOf: lCols)
            lOffset += lCols.count

            uRowPointers.append(uOffset)
            let uCols = uSets[k].sorted()
            uColumnIndices.append(contentsOf: uCols)
            uOffset += uCols.count
        }
        lRowPointers.append(lOffset)
        uRowPointers.append(uOffset)

        // Build the combined L+U structure consumed by the numeric solve.
        var combinedEntries: [(row: Int, col: Int)] = []
        combinedEntries.reserveCapacity(totalLNNZ + totalUNNZ)

        for k in 0..<n {
            for j in lSets[k] {
                combinedEntries.append((row: k, col: j))
            }
            for j in uSets[k] {
                combinedEntries.append((row: k, col: j))
            }
        }

        let factorizationStructure = SparseStructure.uncheckedFromTriplets(
            dimension: n,
            entries: combinedEntries
        )

        // Fill-in = new entries - original entries (accounting for diagonal)
        let fillInCount = factorizationStructure.nonZeroCount - originalNNZ

        return SymbolicAnalysis(
            permutation: perm,
            eliminationTree: eliminationTree,
            fillInCount: max(0, fillInCount),
            factorizationStructure: factorizationStructure,
            lRowPointers: lRowPointers,
            lColumnIndices: lColumnIndices,
            uRowPointers: uRowPointers,
            uColumnIndices: uColumnIndices
        )
    }

    /// Builds an adjacency structure with the given permutation applied.
    private static func buildReorderedAdjacency(
        structure: SparseStructure,
        permutation: Permutation
    ) -> [Set<Int>] {
        let n = structure.dimension
        var adjacency = Array(repeating: Set<Int>(), count: n)

        for oldRow in 0..<n {
            let newRow = permutation.forward[oldRow]
            let start = structure.rowPointers[oldRow]
            let end = structure.rowPointers[oldRow + 1]

            for idx in start..<end {
                let oldCol = structure.columnIndices[idx]
                let newCol = permutation.forward[oldCol]
                adjacency[newRow].insert(newCol)
            }
        }

        return adjacency
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

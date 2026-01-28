/// Result of a symbolic analysis of a sparse matrix structure.
///
/// Symbolic analysis predicts fill-in during LU factorization and
/// produces the structure that the factorized matrix will occupy.
public struct SymbolicAnalysis: Sendable {

    /// Number of additional non-zero entries introduced by factorization.
    public let fillInCount: Int

    /// The sparsity pattern of the LU factors including any fill-in.
    public let factorizationStructure: SparseStructure

    /// Analyzes the given sparsity pattern for fill-in.
    ///
    /// This implementation ensures the diagonal is present and returns
    /// the original structure augmented with any missing diagonal entries.
    /// A production implementation would perform a symbolic Gaussian
    /// elimination to predict off-diagonal fill-in.
    ///
    /// - Parameter structure: The original sparsity pattern.
    /// - Returns: The analysis result.
    public static func analyze(structure: SparseStructure) -> SymbolicAnalysis {
        let n = structure.dimension

        // Collect all existing positions.
        var entries: [(row: Int, col: Int)] = []
        entries.reserveCapacity(structure.nonZeroCount + n)

        for row in 0..<n {
            let start = structure.rowPointers[row]
            let end = structure.rowPointers[row + 1]
            for idx in start..<end {
                entries.append((row: row, col: structure.columnIndices[idx]))
            }
        }

        // Ensure the diagonal is present.
        let originalCount = structure.nonZeroCount
        for i in 0..<n {
            if structure.index(row: i, col: i) == nil {
                entries.append((row: i, col: i))
            }
        }

        let factorizationStructure = SparseStructure.fromTriplets(
            dimension: n,
            entries: entries
        )

        let fillInCount = factorizationStructure.nonZeroCount - originalCount

        return SymbolicAnalysis(
            fillInCount: fillInCount,
            factorizationStructure: factorizationStructure
        )
    }
}

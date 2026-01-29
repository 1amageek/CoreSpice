/// A real-valued sparse matrix stored in CSR format.
///
/// Numeric values are stored in a flat array whose layout matches
/// the positions described by ``SparseStructure``.
public struct SparseMatrix: Sendable {

    /// The sparsity pattern.
    public let structure: SparseStructure

    /// Non-zero values in CSR order.
    public private(set) var values: [Double]

    /// Matrix dimension (number of rows and columns).
    public var dimension: Int { structure.dimension }

    /// Creates a zero-filled matrix with the given sparsity pattern.
    public init(structure: SparseStructure) {
        self.structure = structure
        self.values = Array(repeating: 0.0, count: structure.nonZeroCount)
    }

    /// Resets all stored values to zero without changing the sparsity pattern.
    public mutating func clear() {
        for i in values.indices {
            values[i] = 0.0
        }
    }

    /// Accumulates a value at the given position.
    ///
    /// The position must exist in the sparsity pattern. If it does not,
    /// this method does nothing.
    ///
    /// - Parameters:
    ///   - row: Row index.
    ///   - col: Column index.
    ///   - value: Value to add to the current entry.
    public mutating func addValue(row: Int, col: Int, value: Double) {
        guard let idx = structure.index(row: row, col: col) else { return }
        values[idx] += value
    }

    /// Returns the value at the given position.
    ///
    /// Returns `0` for positions outside the sparsity pattern.
    public func value(row: Int, col: Int) -> Double {
        guard let idx = structure.index(row: row, col: col) else { return 0 }
        return values[idx]
    }

    /// Computes the matrix-vector product `A * vector`.
    ///
    /// - Parameter vector: A vector of length ``dimension``.
    /// - Returns: The result vector of length ``dimension``.
    public func multiply(vector: [Double]) -> [Double] {
        let n = structure.dimension
        var result = Array(repeating: 0.0, count: n)
        for row in 0..<n {
            let start = structure.rowPointers[row]
            let end = structure.rowPointers[row + 1]
            var sum = 0.0
            for idx in start..<end {
                sum += values[idx] * vector[structure.columnIndices[idx]]
            }
            result[row] = sum
        }
        return result
    }

    /// Returns a new matrix with rows and columns permuted.
    ///
    /// Given permutation P, returns P * A * P^T.
    ///
    /// - Parameter permutation: The permutation to apply.
    /// - Returns: The permuted matrix.
    public func permute(_ permutation: Permutation) -> SparseMatrix {
        let n = dimension

        // Collect entries in new ordering
        var entries: [(row: Int, col: Int, value: Double)] = []
        entries.reserveCapacity(structure.nonZeroCount)

        for oldRow in 0..<n {
            let newRow = permutation.forward[oldRow]
            let start = structure.rowPointers[oldRow]
            let end = structure.rowPointers[oldRow + 1]

            for idx in start..<end {
                let oldCol = structure.columnIndices[idx]
                let newCol = permutation.forward[oldCol]
                entries.append((row: newRow, col: newCol, value: values[idx]))
            }
        }

        // Sort by (row, col) for CSR construction
        entries.sort { ($0.row, $0.col) < ($1.row, $1.col) }

        // Build new structure
        var rowPointers = [Int]()
        var columnIndices = [Int]()
        var newValues = [Double]()

        rowPointers.reserveCapacity(n + 1)
        columnIndices.reserveCapacity(entries.count)
        newValues.reserveCapacity(entries.count)

        var currentRow = 0
        rowPointers.append(0)

        for entry in entries {
            while currentRow < entry.row {
                currentRow += 1
                rowPointers.append(columnIndices.count)
            }
            columnIndices.append(entry.col)
            newValues.append(entry.value)
        }

        while currentRow < n {
            currentRow += 1
            rowPointers.append(columnIndices.count)
        }

        let newStructure = SparseStructure(
            dimension: n,
            rowPointers: rowPointers,
            columnIndices: columnIndices
        )

        var result = SparseMatrix(structure: newStructure)
        result.values = newValues
        return result
    }

    /// Extracts a dense representation of the matrix.
    ///
    /// - Returns: A 2D array in row-major order.
    public func toDense() -> [[Double]] {
        let n = dimension
        var dense = Array(repeating: Array(repeating: 0.0, count: n), count: n)

        for row in 0..<n {
            let start = structure.rowPointers[row]
            let end = structure.rowPointers[row + 1]
            for idx in start..<end {
                let col = structure.columnIndices[idx]
                dense[row][col] = values[idx]
            }
        }

        return dense
    }
}

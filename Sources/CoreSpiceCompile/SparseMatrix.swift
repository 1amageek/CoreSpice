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
}

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A typed sparse matrix operation failure.
public enum SparseMatrixError: Error, Equatable, Sendable, CustomStringConvertible {
    case vectorLengthMismatch(expected: Int, actual: Int)
    case rhsLengthMismatch(expected: Int, actual: Int)
    case resultLengthMismatch(expected: Int, actual: Int)
    case nonFiniteMatrixValue(row: Int, column: Int)
    case nonFiniteVectorValue(index: Int)
    case nonFiniteRHSValue(index: Int)
    case residualOverflow(row: Int)

    public var description: String {
        switch self {
        case .vectorLengthMismatch(let expected, let actual):
            return "Sparse matrix vector length \(actual) does not match matrix dimension \(expected)."
        case .rhsLengthMismatch(let expected, let actual):
            return "Sparse matrix RHS length \(actual) does not match matrix dimension \(expected)."
        case .resultLengthMismatch(let expected, let actual):
            return "Sparse matrix result length \(actual) does not match matrix dimension \(expected)."
        case .nonFiniteMatrixValue(let row, let column):
            return "Sparse matrix value at row \(row), column \(column) is not finite."
        case .nonFiniteVectorValue(let index):
            return "Sparse matrix residual vector value at index \(index) is not finite."
        case .nonFiniteRHSValue(let index):
            return "Sparse matrix residual RHS value at index \(index) is not finite."
        case .residualOverflow(let row):
            return "Sparse matrix residual arithmetic overflowed at row \(row)."
        }
    }
}

/// A real-valued sparse matrix stored in CSR format.
///
/// Numeric values are stored in a flat array whose layout matches
/// the positions described by ``SparseStructure``.
public struct SparseMatrix: Sendable {

    /// The sparsity pattern.
    public let structure: SparseStructure

    /// Non-zero values in CSR order.
    public private(set) var values: [Double]

    /// Stamps that targeted positions missing from the sparsity pattern.
    public private(set) var structuralMisses: [SparseMatrixStructuralMiss]

    /// Matrix dimension (number of rows and columns).
    public var dimension: Int { structure.dimension }

    /// Creates a zero-filled matrix with the given sparsity pattern.
    public init(structure: SparseStructure) {
        self.structure = structure
        self.values = Array(repeating: 0.0, count: structure.nonZeroCount)
        self.structuralMisses = []
    }

    /// Resets all stored values to zero without changing the sparsity pattern.
    public mutating func clear() {
        values.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress {
                memset(base, 0, buf.count &* MemoryLayout<Double>.stride)
            }
        }
        structuralMisses.removeAll(keepingCapacity: true)
    }

    /// Accumulates a value at the given position.
    ///
    /// The position must exist in the sparsity pattern.
    ///
    /// - Parameters:
    ///   - row: Row index.
    ///   - col: Column index.
    ///   - value: Value to add to the current entry.
    public mutating func addValue(row: Int, col: Int, value: Double) {
        guard let idx = structure.index(row: row, col: col) else {
            structuralMisses.append(SparseMatrixStructuralMiss(row: row, col: col))
            return
        }
        values[idx] += value
    }

    /// Accumulates a value at a pre-resolved CSR index, bypassing binary search.
    ///
    /// The caller must ensure the index was obtained from the same
    /// ``SparseStructure`` used to create this matrix.
    @inline(__always)
    public mutating func addValueDirect(at valueIndex: Int, value: Double) {
        values[valueIndex] += value
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
    public func multiply(vector: [Double]) throws -> [Double] {
        try checkedMultiply(vector: vector)
    }

    /// Computes the matrix-vector product `A * vector` with typed validation.
    public func checkedMultiply(vector: [Double]) throws -> [Double] {
        let n = structure.dimension
        var result = Array(repeating: 0.0, count: n)
        try checkedMultiply(vector: vector, into: &result)
        return result
    }

    /// Computes the matrix-vector product `A * vector` into caller-owned storage.
    ///
    /// This is the zero-allocation variant of ``multiply(vector:)``.
    public func multiply(vector: [Double], into result: inout [Double]) throws {
        try checkedMultiply(vector: vector, into: &result)
    }

    /// Computes the matrix-vector product into caller-owned storage with typed validation.
    public func checkedMultiply(vector: [Double], into result: inout [Double]) throws {
        let n = structure.dimension
        guard result.count == n else {
            throw SparseMatrixError.resultLengthMismatch(expected: n, actual: result.count)
        }
        guard vector.count == n else {
            throw SparseMatrixError.vectorLengthMismatch(expected: n, actual: vector.count)
        }
        for row in 0..<n {
            let start = structure.rowPointers[row]
            let end = structure.rowPointers[row + 1]
            var sum = 0.0
            for idx in start..<end {
                sum += values[idx] * vector[structure.columnIndices[idx]]
            }
            result[row] = sum
        }
    }

    /// Evaluates signed `A * vector - rhs` with product and summation compensation.
    /// The caller owns output storage; any thrown error invalidates its contents.
    package func checkedResidual(
        vector: borrowing [Double], rhs: borrowing [Double], into result: inout [Double]
    ) throws {
        let n = dimension
        guard result.count == n else {
            throw SparseMatrixError.resultLengthMismatch(expected: n, actual: result.count)
        }
        guard vector.count == n else {
            throw SparseMatrixError.vectorLengthMismatch(expected: n, actual: vector.count)
        }
        guard rhs.count == n else {
            throw SparseMatrixError.rhsLengthMismatch(expected: n, actual: rhs.count)
        }
        for index in 0..<n {
            guard vector[index].isFinite else { throw SparseMatrixError.nonFiniteVectorValue(index: index) }
            guard rhs[index].isFinite else { throw SparseMatrixError.nonFiniteRHSValue(index: index) }
        }
        for row in 0..<n {
            var sum = 0.0
            var correction = 0.0
            for index in structure.rowPointers[row]..<structure.rowPointers[row + 1] {
                let column = structure.columnIndices[index]
                let coefficient = values[index]
                guard coefficient.isFinite else {
                    throw SparseMatrixError.nonFiniteMatrixValue(row: row, column: column)
                }
                let product = coefficient * vector[column]
                guard product.isFinite else { throw SparseMatrixError.residualOverflow(row: row) }
                // FMA retains the product error that summation compensation alone cannot recover.
                let productError = (-product).addingProduct(coefficient, vector[column])
                guard productError.isFinite else { throw SparseMatrixError.residualOverflow(row: row) }
                try Self.accumulateResidual(product, productError: productError, row: row,
                    sum: &sum, correction: &correction)
            }
            try Self.accumulateResidual(-rhs[row], productError: 0, row: row,
                sum: &sum, correction: &correction)
            let residual = sum + correction
            guard residual.isFinite else { throw SparseMatrixError.residualOverflow(row: row) }
            result[row] = residual
        }
    }

    @inline(__always)
    private static func accumulateResidual(_ term: Double, productError: Double, row: Int,
        sum: inout Double, correction: inout Double) throws {
        let next = sum + term
        guard next.isFinite else { throw SparseMatrixError.residualOverflow(row: row) }
        let sumError = abs(sum) >= abs(term) ? (sum - next) + term : (term - next) + sum
        let error = sumError + productError
        guard error.isFinite else { throw SparseMatrixError.residualOverflow(row: row) }
        let nextCorrection = correction + error
        guard nextCorrection.isFinite else { throw SparseMatrixError.residualOverflow(row: row) }
        sum = next
        correction = nextCorrection
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
            uncheckedDimension: n,
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

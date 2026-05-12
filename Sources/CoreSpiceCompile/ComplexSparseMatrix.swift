#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A pair of double-precision values representing a complex number.
public struct ComplexPair: Sendable, Hashable {

    public var real: Double
    public var imag: Double

    public init(real: Double = 0, imag: Double = 0) {
        self.real = real
        self.imag = imag
    }

    /// The magnitude (absolute value) of the complex number.
    public var magnitude: Double {
        (real * real + imag * imag).squareRoot()
    }

    /// The complex conjugate.
    public var conjugate: ComplexPair {
        ComplexPair(real: real, imag: -imag)
    }

    public static func + (lhs: ComplexPair, rhs: ComplexPair) -> ComplexPair {
        ComplexPair(real: lhs.real + rhs.real, imag: lhs.imag + rhs.imag)
    }

    public static func - (lhs: ComplexPair, rhs: ComplexPair) -> ComplexPair {
        ComplexPair(real: lhs.real - rhs.real, imag: lhs.imag - rhs.imag)
    }

    public static func * (lhs: ComplexPair, rhs: ComplexPair) -> ComplexPair {
        ComplexPair(
            real: lhs.real * rhs.real - lhs.imag * rhs.imag,
            imag: lhs.real * rhs.imag + lhs.imag * rhs.real
        )
    }

    public static func / (lhs: ComplexPair, rhs: ComplexPair) -> ComplexPair {
        let denom = rhs.real * rhs.real + rhs.imag * rhs.imag
        return ComplexPair(
            real: (lhs.real * rhs.real + lhs.imag * rhs.imag) / denom,
            imag: (lhs.imag * rhs.real - lhs.real * rhs.imag) / denom
        )
    }

    /// The additive identity.
    public static let zero = ComplexPair(real: 0, imag: 0)

    /// The multiplicative identity.
    public static let one = ComplexPair(real: 1, imag: 0)
}

/// A complex-valued sparse matrix stored in CSR format.
///
/// Uses the same sparsity structure as ``SparseMatrix`` but stores
/// ``ComplexPair`` values.
public struct ComplexSparseMatrix: Sendable {

    /// The sparsity pattern.
    public let structure: SparseStructure

    /// Non-zero complex values in CSR order.
    public private(set) var values: [ComplexPair]

    /// Stamps that targeted positions missing from the sparsity pattern.
    public private(set) var structuralMisses: [SparseMatrixStructuralMiss]

    /// Matrix dimension (number of rows and columns).
    public var dimension: Int { structure.dimension }

    /// Creates a zero-filled complex matrix with the given sparsity pattern.
    public init(structure: SparseStructure) {
        self.structure = structure
        self.values = Array(repeating: .zero, count: structure.nonZeroCount)
        self.structuralMisses = []
    }

    /// Resets all stored values to zero without changing the sparsity pattern.
    public mutating func clear() {
        values.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress {
                // ComplexPair is two Doubles; all-zero bits == (real: 0, imag: 0)
                memset(base, 0, buf.count &* MemoryLayout<ComplexPair>.stride)
            }
        }
        structuralMisses.removeAll(keepingCapacity: true)
    }

    /// Accumulates a complex value at the given position.
    ///
    /// The position must exist in the sparsity pattern.
    public mutating func addValue(row: Int, col: Int, value: ComplexPair) {
        guard let idx = structure.index(row: row, col: col) else {
            structuralMisses.append(SparseMatrixStructuralMiss(row: row, col: col))
            return
        }
        values[idx] = values[idx] + value
    }

    /// Returns the complex value at the given position.
    ///
    /// Returns ``ComplexPair/zero`` for positions outside the sparsity pattern.
    public func value(row: Int, col: Int) -> ComplexPair {
        guard let idx = structure.index(row: row, col: col) else { return .zero }
        return values[idx]
    }

    /// Computes the matrix-vector product `A * vector`.
    ///
    /// - Parameter vector: A complex vector of length ``dimension``.
    /// - Returns: The result vector of length ``dimension``.
    public func multiply(vector: [ComplexPair]) -> [ComplexPair] {
        let n = structure.dimension
        var result = Array(repeating: ComplexPair.zero, count: n)
        for row in 0..<n {
            let start = structure.rowPointers[row]
            let end = structure.rowPointers[row + 1]
            var sum = ComplexPair.zero
            for idx in start..<end {
                sum = sum + values[idx] * vector[structure.columnIndices[idx]]
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
    public func permute(_ permutation: Permutation) -> ComplexSparseMatrix {
        let n = dimension

        // Collect entries in new ordering
        var entries: [(row: Int, col: Int, value: ComplexPair)] = []
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
        var newValues = [ComplexPair]()

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

        var result = ComplexSparseMatrix(structure: newStructure)
        result.values = newValues
        return result
    }

    /// Extracts a dense representation of the matrix.
    ///
    /// - Returns: A 2D array in row-major order.
    public func toDense() -> [[ComplexPair]] {
        let n = dimension
        var dense = Array(repeating: Array(repeating: ComplexPair.zero, count: n), count: n)

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

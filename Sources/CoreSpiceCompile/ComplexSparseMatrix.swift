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

    /// Matrix dimension (number of rows and columns).
    public var dimension: Int { structure.dimension }

    /// Creates a zero-filled complex matrix with the given sparsity pattern.
    public init(structure: SparseStructure) {
        self.structure = structure
        self.values = Array(repeating: .zero, count: structure.nonZeroCount)
    }

    /// Resets all stored values to zero without changing the sparsity pattern.
    public mutating func clear() {
        for i in values.indices {
            values[i] = .zero
        }
    }

    /// Accumulates a complex value at the given position.
    ///
    /// The position must exist in the sparsity pattern.
    public mutating func addValue(row: Int, col: Int, value: ComplexPair) {
        guard let idx = structure.index(row: row, col: col) else { return }
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
}

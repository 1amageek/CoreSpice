public enum SparseStructureError: Error, Sendable, Equatable, CustomStringConvertible {
    case negativeDimension(Int)
    case dimensionTooLarge(Int)
    case rowPointerCount(expected: Int, actual: Int)
    case firstRowPointer(Int)
    case nonMonotonicRowPointer(row: Int, previous: Int, current: Int)
    case terminalRowPointer(expected: Int, actual: Int)
    case columnOutOfBounds(row: Int, column: Int, dimension: Int)
    case columnsNotStrictlyIncreasing(row: Int, previous: Int, current: Int)
    case tripletOutOfBounds(row: Int, column: Int, dimension: Int)

    public var description: String {
        switch self {
        case .negativeDimension(let dimension):
            "Sparse structure dimension must be nonnegative; received \(dimension)."
        case .dimensionTooLarge(let dimension):
            "Sparse structure dimension \(dimension) cannot be represented safely."
        case .rowPointerCount(let expected, let actual):
            "CSR row pointer count must be \(expected); received \(actual)."
        case .firstRowPointer(let value):
            "CSR first row pointer must be zero; received \(value)."
        case .nonMonotonicRowPointer(let row, let previous, let current):
            "CSR row pointer \(row) decreased from \(previous) to \(current)."
        case .terminalRowPointer(let expected, let actual):
            "CSR terminal row pointer must equal column count \(expected); received \(actual)."
        case .columnOutOfBounds(let row, let column, let dimension):
            "CSR column \(column) in row \(row) is outside 0..<\(dimension)."
        case .columnsNotStrictlyIncreasing(let row, let previous, let current):
            "CSR columns in row \(row) are not strictly increasing: \(previous), \(current)."
        case .tripletOutOfBounds(let row, let column, let dimension):
            "Sparse triplet (\(row), \(column)) is outside a \(dimension)x\(dimension) matrix."
        }
    }
}

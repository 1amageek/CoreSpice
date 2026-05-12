/// A matrix stamp that targeted a position missing from the CSR structure.
public struct SparseMatrixStructuralMiss: Sendable, Equatable {

    public let row: Int
    public let col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }
}

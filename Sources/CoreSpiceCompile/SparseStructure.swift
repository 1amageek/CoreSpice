/// Compressed Sparse Row (CSR) sparsity pattern.
///
/// Stores only the structural positions of non-zero entries.
/// The actual numeric values are held separately by ``SparseMatrix``
/// or ``ComplexSparseMatrix``.
public struct SparseStructure: Sendable, Equatable {

    /// The number of rows (and columns) in the square matrix.
    public let dimension: Int

    /// Row pointers into ``columnIndices``. Length is ``dimension`` + 1.
    ///
    /// Row `i` spans the column index range `rowPointers[i] ..< rowPointers[i+1]`.
    public let rowPointers: [Int]

    /// Column indices for every non-zero position. Length equals ``nonZeroCount``.
    public let columnIndices: [Int]

    /// The number of structural non-zero positions.
    public var nonZeroCount: Int { columnIndices.count }

    /// Creates a CSR sparsity pattern from pre-computed arrays.
    ///
    /// - Parameters:
    ///   - dimension: Matrix dimension (rows and columns).
    ///   - rowPointers: Row pointer array of length `dimension + 1`.
    ///   - columnIndices: Sorted column indices for each row.
    public init(dimension: Int, rowPointers: [Int], columnIndices: [Int]) throws {
        try Self.validate(
            dimension: dimension,
            rowPointers: rowPointers,
            columnIndices: columnIndices
        )
        self.dimension = dimension
        self.rowPointers = rowPointers
        self.columnIndices = columnIndices
    }

    init(
        uncheckedDimension dimension: Int,
        rowPointers: [Int],
        columnIndices: [Int]
    ) {
        self.dimension = dimension
        self.rowPointers = rowPointers
        self.columnIndices = columnIndices
    }

    /// Builds a CSR sparsity pattern from coordinate triplets.
    ///
    /// Duplicate entries are merged and columns within each row are sorted
    /// in ascending order.
    ///
    /// - Parameters:
    ///   - dimension: Matrix dimension.
    ///   - entries: Coordinate pairs `(row, col)` describing non-zero positions.
    /// - Returns: A deduplicated, sorted ``SparseStructure``.
    public static func fromTriplets(
        dimension: Int,
        entries: [(row: Int, col: Int)]
    ) throws -> SparseStructure {
        guard dimension >= 0 else {
            throw SparseStructureError.negativeDimension(dimension)
        }
        // Deduplicate by collecting into a set.
        var unique = Set<MatrixPosition>()
        unique.reserveCapacity(entries.count)
        for entry in entries {
            guard entry.row >= 0, entry.row < dimension,
                  entry.col >= 0, entry.col < dimension else {
                throw SparseStructureError.tripletOutOfBounds(
                    row: entry.row,
                    column: entry.col,
                    dimension: dimension
                )
            }
            unique.insert(MatrixPosition(row: entry.row, col: entry.col))
        }

        // Group by row and sort columns within each row.
        var rowBuckets: [[Int]] = Array(repeating: [], count: dimension)
        for pos in unique {
            rowBuckets[pos.row].append(pos.col)
        }

        var rowPointers = [Int]()
        rowPointers.reserveCapacity(dimension + 1)
        var columnIndices = [Int]()
        columnIndices.reserveCapacity(unique.count)

        var offset = 0
        for row in 0..<dimension {
            rowPointers.append(offset)
            let sorted = rowBuckets[row].sorted()
            columnIndices.append(contentsOf: sorted)
            offset += sorted.count
        }
        rowPointers.append(offset)

        return SparseStructure(
            uncheckedDimension: dimension,
            rowPointers: rowPointers,
            columnIndices: columnIndices
        )
    }

    static func uncheckedFromTriplets(
        dimension: Int,
        entries: [(row: Int, col: Int)]
    ) -> SparseStructure {
        var unique = Set<MatrixPosition>()
        unique.reserveCapacity(entries.count)
        for entry in entries {
            unique.insert(MatrixPosition(row: entry.row, col: entry.col))
        }
        var rowBuckets = Array(repeating: [Int](), count: dimension)
        for position in unique {
            rowBuckets[position.row].append(position.col)
        }
        var rowPointers: [Int] = []
        var columnIndices: [Int] = []
        rowPointers.reserveCapacity(dimension + 1)
        columnIndices.reserveCapacity(unique.count)
        for row in 0..<dimension {
            rowPointers.append(columnIndices.count)
            columnIndices.append(contentsOf: rowBuckets[row].sorted())
        }
        rowPointers.append(columnIndices.count)
        return SparseStructure(
            uncheckedDimension: dimension,
            rowPointers: rowPointers,
            columnIndices: columnIndices
        )
    }

    private static func validate(
        dimension: Int,
        rowPointers: [Int],
        columnIndices: [Int]
    ) throws {
        guard dimension >= 0 else {
            throw SparseStructureError.negativeDimension(dimension)
        }
        let (expectedRowPointerCount, overflow) = dimension.addingReportingOverflow(1)
        guard !overflow else {
            throw SparseStructureError.dimensionTooLarge(dimension)
        }
        guard rowPointers.count == expectedRowPointerCount else {
            throw SparseStructureError.rowPointerCount(
                expected: expectedRowPointerCount,
                actual: rowPointers.count
            )
        }
        guard rowPointers.first == 0 else {
            throw SparseStructureError.firstRowPointer(rowPointers.first ?? -1)
        }
        for row in 0..<dimension {
            let start = rowPointers[row]
            let end = rowPointers[row + 1]
            guard start <= end else {
                throw SparseStructureError.nonMonotonicRowPointer(
                    row: row + 1,
                    previous: start,
                    current: end
                )
            }
            guard start >= 0, end <= columnIndices.count else {
                throw SparseStructureError.terminalRowPointer(
                    expected: columnIndices.count,
                    actual: end
                )
            }
            var previous: Int?
            for index in start..<end {
                let column = columnIndices[index]
                guard column >= 0, column < dimension else {
                    throw SparseStructureError.columnOutOfBounds(
                        row: row,
                        column: column,
                        dimension: dimension
                    )
                }
                if let previous, column <= previous {
                    throw SparseStructureError.columnsNotStrictlyIncreasing(
                        row: row,
                        previous: previous,
                        current: column
                    )
                }
                previous = column
            }
        }
        guard rowPointers.last == columnIndices.count else {
            throw SparseStructureError.terminalRowPointer(
                expected: columnIndices.count,
                actual: rowPointers.last ?? -1
            )
        }
    }

    /// Finds the storage index for the element at `(row, col)`.
    ///
    /// - Returns: The index into the values array, or `nil` if the position
    ///   is not part of the sparsity pattern.
    public func index(row: Int, col: Int) -> Int? {
        guard row >= 0, row < dimension, col >= 0, col < dimension else {
            return nil
        }

        let start = rowPointers[row]
        let end = rowPointers[row + 1]

        // Binary search within the row's column indices.
        var lo = start
        var hi = end
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if columnIndices[mid] < col {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo < end, columnIndices[lo] == col {
            return lo
        }
        return nil
    }
}

// MARK: - Internal Helpers

/// A hashable row/column pair used for deduplication.
private struct MatrixPosition: Hashable {
    let row: Int
    let col: Int
}

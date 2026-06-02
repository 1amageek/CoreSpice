/// Row-major storage for a sequence of MNA solution vectors.
///
/// Values are stored as `[point0_var0, point0_var1, ..., point1_var0, ...]`.
/// This avoids the nested-array copy-on-write churn of `[[Double]]` while
/// preserving O(1) indexed access for analysis and export paths.
public struct SolutionTrace: Sendable {
    public let variableCount: Int
    private var values: [Double]

    public var pointCount: Int {
        guard variableCount > 0 else { return 0 }
        return values.count / variableCount
    }

    public var rowMajorValues: [Double] {
        values
    }

    public init(variableCount: Int, estimatedPointCapacity: Int = 0) {
        self.variableCount = variableCount
        self.values = []
        if variableCount > 0, estimatedPointCapacity > 0 {
            values.reserveCapacity(variableCount * estimatedPointCapacity)
        }
    }

    public init(variableCount: Int, rowMajorValues: [Double]) {
        precondition(variableCount >= 0, "variableCount must not be negative")
        precondition(
            variableCount == 0 ? rowMajorValues.isEmpty : rowMajorValues.count.isMultiple(of: variableCount),
            "rowMajorValues count must be a multiple of variableCount"
        )
        self.variableCount = variableCount
        self.values = rowMajorValues
    }

    public mutating func append(_ solution: [Double]) {
        precondition(solution.count == variableCount, "solution width must match variableCount")
        values.append(contentsOf: solution)
    }

    public mutating func append(_ solution: UnsafeBufferPointer<Double>) {
        precondition(solution.count == variableCount, "solution width must match variableCount")
        values.append(contentsOf: solution)
    }

    public func value(pointIndex: Int, variableIndex: Int) -> Double {
        precondition(pointIndex >= 0 && pointIndex < pointCount, "pointIndex out of range")
        precondition(variableIndex >= 0 && variableIndex < variableCount, "variableIndex out of range")
        return values[(pointIndex * variableCount) + variableIndex]
    }

    public func withPoint<R>(
        at pointIndex: Int,
        _ body: (UnsafeBufferPointer<Double>) throws -> R
    ) rethrows -> R {
        precondition(pointIndex >= 0 && pointIndex < pointCount, "pointIndex out of range")
        let start = pointIndex * variableCount
        return try values.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress! + start
            return try body(UnsafeBufferPointer(start: base, count: variableCount))
        }
    }

    public func column(variableIndex: Int) -> SolutionTraceColumn {
        precondition(variableIndex >= 0 && variableIndex < variableCount, "variableIndex out of range")
        return SolutionTraceColumn(
            values: values,
            variableIndex: variableIndex,
            variableCount: variableCount
        )
    }
}

public struct SolutionTraceColumn: RandomAccessCollection, Sendable {
    public typealias Index = Int
    public typealias Element = Double

    private let values: [Double]
    private let variableIndex: Int
    private let variableCount: Int

    public var startIndex: Int { 0 }

    public var endIndex: Int {
        guard variableCount > 0 else { return 0 }
        return values.count / variableCount
    }

    init(values: [Double], variableIndex: Int, variableCount: Int) {
        self.values = values
        self.variableIndex = variableIndex
        self.variableCount = variableCount
    }

    public subscript(position: Int) -> Double {
        values[(position * variableCount) + variableIndex]
    }
}

import Foundation

/// Row-major storage for a sequence of MNA solution vectors.
///
/// Values are stored as `[point0_var0, point0_var1, ..., point1_var0, ...]`.
/// This avoids the nested-array copy-on-write churn of `[[Double]]` while
/// preserving O(1) indexed access for analysis and export paths.
public struct SolutionTrace: Sendable {
    public enum ValidationError: Error, LocalizedError, Equatable, Sendable {
        case negativeVariableCount(Int)
        case invalidRowMajorValueCount(variableCount: Int, valueCount: Int)
        case solutionWidthMismatch(expected: Int, actual: Int)
        case pointIndexOutOfRange(index: Int, pointCount: Int)
        case variableIndexOutOfRange(index: Int, variableCount: Int)
        case missingPointStorage

        public var errorDescription: String? {
            switch self {
            case .negativeVariableCount(let count):
                return "Solution trace variable count must not be negative: \(count)."
            case .invalidRowMajorValueCount(let variableCount, let valueCount):
                return "Row-major value count \(valueCount) is not valid for variable count \(variableCount)."
            case .solutionWidthMismatch(let expected, let actual):
                return "Solution width \(actual) does not match variable count \(expected)."
            case .pointIndexOutOfRange(let index, let pointCount):
                return "Point index \(index) is outside 0..<\(pointCount)."
            case .variableIndexOutOfRange(let index, let variableCount):
                return "Variable index \(index) is outside 0..<\(variableCount)."
            case .missingPointStorage:
                return "Solution trace point storage is unavailable."
            }
        }
    }

    public let variableCount: Int
    private var values: [Double]

    public var pointCount: Int {
        guard variableCount > 0 else { return 0 }
        return values.count / variableCount
    }

    public var rowMajorValues: [Double] {
        values
    }

    public init(variableCount: Int, estimatedPointCapacity: Int = 0) throws {
        guard variableCount >= 0 else {
            throw ValidationError.negativeVariableCount(variableCount)
        }
        self.variableCount = variableCount
        self.values = []
        if variableCount > 0, estimatedPointCapacity > 0 {
            values.reserveCapacity(variableCount * estimatedPointCapacity)
        }
    }

    public init(variableCount: Int, rowMajorValues: [Double]) throws {
        guard variableCount >= 0 else {
            throw ValidationError.negativeVariableCount(variableCount)
        }
        guard variableCount == 0 ? rowMajorValues.isEmpty : rowMajorValues.count.isMultiple(of: variableCount) else {
            throw ValidationError.invalidRowMajorValueCount(
                variableCount: variableCount,
                valueCount: rowMajorValues.count
            )
        }
        self.variableCount = variableCount
        self.values = rowMajorValues
    }

    public mutating func append(_ solution: [Double]) throws {
        guard solution.count == variableCount else {
            throw ValidationError.solutionWidthMismatch(expected: variableCount, actual: solution.count)
        }
        values.append(contentsOf: solution)
    }

    public mutating func append(_ solution: UnsafeBufferPointer<Double>) throws {
        guard solution.count == variableCount else {
            throw ValidationError.solutionWidthMismatch(expected: variableCount, actual: solution.count)
        }
        values.append(contentsOf: solution)
    }

    public func value(pointIndex: Int, variableIndex: Int) throws -> Double {
        try validate(pointIndex: pointIndex)
        try validate(variableIndex: variableIndex)
        return values[(pointIndex * variableCount) + variableIndex]
    }

    public func withPoint<R>(
        at pointIndex: Int,
        _ body: (UnsafeBufferPointer<Double>) throws -> R
    ) throws -> R {
        try validate(pointIndex: pointIndex)
        let start = pointIndex * variableCount
        return try values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                throw ValidationError.missingPointStorage
            }
            return try body(UnsafeBufferPointer(start: base.advanced(by: start), count: variableCount))
        }
    }

    public func column(variableIndex: Int) throws -> SolutionTraceColumn {
        try validate(variableIndex: variableIndex)
        return SolutionTraceColumn(
            values: values,
            variableIndex: variableIndex,
            variableCount: variableCount
        )
    }

    private func validate(pointIndex: Int) throws {
        guard pointIndex >= 0 && pointIndex < pointCount else {
            throw ValidationError.pointIndexOutOfRange(index: pointIndex, pointCount: pointCount)
        }
    }

    private func validate(variableIndex: Int) throws {
        guard variableIndex >= 0 && variableIndex < variableCount else {
            throw ValidationError.variableIndexOutOfRange(index: variableIndex, variableCount: variableCount)
        }
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

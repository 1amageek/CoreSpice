/// A borrowed real-valued row-major buffer with optional row stride and start offset.
///
/// The buffer is valid only during the borrowing closure that provides it.
/// Rows are contiguous for `variableCount` values, while consecutive visible
/// rows may be separated by `rowStride` values in the backing storage.
public struct RealRowMajorBuffer {
    public let values: UnsafeBufferPointer<Double>
    public let pointCount: Int
    public let variableCount: Int
    public let rowStride: Int
    public let startOffset: Int

    public init(
        values: UnsafeBufferPointer<Double>,
        pointCount: Int,
        variableCount: Int,
        rowStride: Int,
        startOffset: Int = 0
    ) {
        self.values = values
        self.pointCount = pointCount
        self.variableCount = variableCount
        self.rowStride = rowStride
        self.startOffset = startOffset
    }

    public func value(point: Int, variable: Int) -> Double? {
        guard point >= 0, point < pointCount else { return nil }
        guard variable >= 0, variable < variableCount else { return nil }
        return values[startOffset + (point * rowStride) + variable]
    }

    public func withRow<R>(
        at point: Int,
        _ body: (UnsafeBufferPointer<Double>) throws -> R
    ) rethrows -> R? {
        guard point >= 0, point < pointCount else { return nil }
        guard variableCount > 0 else {
            return try body(UnsafeBufferPointer(start: nil, count: 0))
        }
        guard let baseAddress = values.baseAddress else {
            preconditionFailure("non-empty row-major buffer must have a base address")
        }
        return try body(
            UnsafeBufferPointer(
                start: baseAddress + startOffset + (point * rowStride),
                count: variableCount
            )
        )
    }
}

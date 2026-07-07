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
        guard let index = storageIndex(point: point, variable: variable) else {
            return nil
        }
        return values[index]
    }

    public func withRow<R>(
        at point: Int,
        _ body: (UnsafeBufferPointer<Double>) throws -> R
    ) rethrows -> R? {
        guard point >= 0, point < pointCount else { return nil }
        guard variableCount >= 0 else { return nil }
        guard variableCount > 0 else {
            return try body(UnsafeBufferPointer(start: nil, count: 0))
        }
        guard let start = storageIndex(point: point, variable: 0) else { return nil }
        guard variableCount <= Int.max - start, start + variableCount <= values.count else {
            return nil
        }
        guard let baseAddress = values.baseAddress else {
            return try body(UnsafeBufferPointer(start: nil, count: 0))
        }
        return try body(
            UnsafeBufferPointer(
                start: baseAddress + start,
                count: variableCount
            )
        )
    }

    private func storageIndex(point: Int, variable: Int) -> Int? {
        guard point >= 0, point < pointCount else { return nil }
        guard variable >= 0, variable < variableCount else { return nil }
        guard pointCount >= 0, variableCount >= 0, rowStride >= 0, startOffset >= 0 else {
            return nil
        }
        guard point == 0 || rowStride <= (Int.max - startOffset) / point else {
            return nil
        }
        let rowStart = startOffset + (point * rowStride)
        guard variable <= Int.max - rowStart else {
            return nil
        }
        let index = rowStart + variable
        guard index >= 0, index < values.count else {
            return nil
        }
        return index
    }
}

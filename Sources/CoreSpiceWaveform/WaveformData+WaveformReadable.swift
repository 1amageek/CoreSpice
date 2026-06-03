extension WaveformData: WaveformReadable {

    /// Returns the sweep value at a point.
    public func sweepValue(at point: Int) -> Double? {
        guard point >= 0, point < sweepValues.count else { return nil }
        return sweepValues[point]
    }

    public func withSweepValues<R>(
        _ body: (UnsafeBufferPointer<Double>) throws -> R
    ) rethrows -> R? {
        try sweepValues.withUnsafeBufferPointer(body)
    }
}

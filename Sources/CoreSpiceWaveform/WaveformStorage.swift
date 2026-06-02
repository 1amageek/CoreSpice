/// Internal storage for waveform data.
///
/// Waveform data can be stored as either real or complex values
/// depending on the analysis type.
public enum WaveformStorage: Sendable {

    /// Real-valued data stored as a 2D array [point][variable].
    case real([[Double]])

    /// Real-valued data stored in row-major order.
    case realRowMajor(values: [Double], pointCount: Int, variableCount: Int)

    /// Complex-valued data stored as a 2D array [point][(real, imag)].
    case complex([[(real: Double, imag: Double)]])

    /// The number of data points.
    public var pointCount: Int {
        switch self {
        case .real(let data):
            return data.count
        case .realRowMajor(_, let pointCount, _):
            return pointCount
        case .complex(let data):
            return data.count
        }
    }

    /// The number of variables per point.
    public var variableCount: Int {
        switch self {
        case .real(let data):
            return data.first?.count ?? 0
        case .realRowMajor(_, _, let variableCount):
            return variableCount
        case .complex(let data):
            return data.first?.count ?? 0
        }
    }

    /// Whether this storage contains complex data.
    public var isComplex: Bool {
        switch self {
        case .real, .realRowMajor:
            return false
        case .complex:
            return true
        }
    }

    /// Gets a real value at the given indices.
    ///
    /// For complex storage, returns the real part.
    public func realValue(point: Int, variable: Int) -> Double? {
        switch self {
        case .real(let data):
            guard point < data.count, variable < data[point].count else { return nil }
            return data[point][variable]
        case .realRowMajor(let values, let pointCount, let variableCount):
            guard point >= 0, point < pointCount, variable >= 0, variable < variableCount else {
                return nil
            }
            return values[(point * variableCount) + variable]
        case .complex(let data):
            guard point < data.count, variable < data[point].count else { return nil }
            return data[point][variable].real
        }
    }

    /// Gets a complex value at the given indices.
    ///
    /// For real storage, returns the value with zero imaginary part.
    public func complexValue(point: Int, variable: Int) -> (real: Double, imag: Double)? {
        switch self {
        case .real(let data):
            guard point < data.count, variable < data[point].count else { return nil }
            return (real: data[point][variable], imag: 0.0)
        case .realRowMajor(let values, let pointCount, let variableCount):
            guard point >= 0, point < pointCount, variable >= 0, variable < variableCount else {
                return nil
            }
            return (real: values[(point * variableCount) + variable], imag: 0.0)
        case .complex(let data):
            guard point < data.count, variable < data[point].count else { return nil }
            return data[point][variable]
        }
    }

    public func withRealValues<R>(
        point: Int,
        _ body: (UnsafeBufferPointer<Double>) throws -> R
    ) rethrows -> R? {
        switch self {
        case .real(let data):
            guard point >= 0, point < data.count else { return nil }
            return try data[point].withUnsafeBufferPointer(body)
        case .realRowMajor(let values, let pointCount, let variableCount):
            guard point >= 0, point < pointCount else { return nil }
            let start = point * variableCount
            return try values.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else {
                    return try body(UnsafeBufferPointer(start: nil, count: 0))
                }
                return try body(UnsafeBufferPointer(start: base + start, count: variableCount))
            }
        case .complex:
            return nil
        }
    }

    public func withComplexValues<R>(
        point: Int,
        _ body: (UnsafeBufferPointer<(real: Double, imag: Double)>) throws -> R
    ) rethrows -> R? {
        switch self {
        case .complex(let data):
            guard point >= 0, point < data.count else { return nil }
            return try data[point].withUnsafeBufferPointer(body)
        case .real, .realRowMajor:
            return nil
        }
    }

    public var realRowMajorValues: (values: [Double], pointCount: Int, variableCount: Int)? {
        switch self {
        case .real(let data):
            let pointCount = data.count
            let variableCount = data.first?.count ?? 0
            var values: [Double] = []
            values.reserveCapacity(pointCount * variableCount)
            for point in data {
                values.append(contentsOf: point)
            }
            return (values, pointCount, variableCount)
        case .realRowMajor(let values, let pointCount, let variableCount):
            return (values, pointCount, variableCount)
        case .complex:
            return nil
        }
    }

    public var materializedRealRows: [[Double]]? {
        switch self {
        case .real(let data):
            return data
        case .realRowMajor(let values, let pointCount, let variableCount):
            var rows: [[Double]] = []
            rows.reserveCapacity(pointCount)
            for point in 0..<pointCount {
                let start = point * variableCount
                rows.append(Array(values[start..<(start + variableCount)]))
            }
            return rows
        case .complex:
            return nil
        }
    }
}

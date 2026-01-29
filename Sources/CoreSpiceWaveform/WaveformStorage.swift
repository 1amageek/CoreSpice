/// Internal storage for waveform data.
///
/// Waveform data can be stored as either real or complex values
/// depending on the analysis type.
public enum WaveformStorage: Sendable {

    /// Real-valued data stored as a 2D array [point][variable].
    case real([[Double]])

    /// Complex-valued data stored as a 2D array [point][(real, imag)].
    case complex([[(real: Double, imag: Double)]])

    /// The number of data points.
    public var pointCount: Int {
        switch self {
        case .real(let data):
            return data.count
        case .complex(let data):
            return data.count
        }
    }

    /// The number of variables per point.
    public var variableCount: Int {
        switch self {
        case .real(let data):
            return data.first?.count ?? 0
        case .complex(let data):
            return data.first?.count ?? 0
        }
    }

    /// Whether this storage contains complex data.
    public var isComplex: Bool {
        switch self {
        case .real:
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
        case .complex(let data):
            guard point < data.count, variable < data[point].count else { return nil }
            return data[point][variable]
        }
    }
}

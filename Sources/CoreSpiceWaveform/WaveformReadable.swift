/// A read-only waveform data source.
///
/// Implementations may own storage or represent a lazy projection over another
/// waveform. Consumers should read through this protocol instead of requiring
/// a materialized `WaveformData`.
public protocol WaveformReadable: Sendable {

    /// Metadata describing the visible waveform.
    var metadata: SimulationMetadata { get }

    /// The visible sweep variable.
    var sweepVariable: VariableDescriptor { get }

    /// Visible variable descriptors.
    var variables: [VariableDescriptor] { get }

    /// Whether visible values are complex-valued.
    var isComplex: Bool { get }

    /// The number of visible points.
    var pointCount: Int { get }

    /// The number of visible variables.
    var variableCount: Int { get }

    /// Returns the visible sweep value at a point.
    func sweepValue(at point: Int) -> Double?

    /// Returns a real value for a visible variable and point.
    func realValue(variable: Int, point: Int) -> Double?

    /// Returns a complex value for a visible variable and point.
    func complexValue(variable: Int, point: Int) -> (real: Double, imag: Double)?

    /// Borrows a contiguous real-valued point buffer when the visible projection is contiguous.
    func withRealValues<R>(
        at point: Int,
        _ body: (UnsafeBufferPointer<Double>) throws -> R
    ) rethrows -> R?

    /// Borrows a contiguous complex-valued point buffer when the visible projection is contiguous.
    func withComplexValues<R>(
        at point: Int,
        _ body: (UnsafeBufferPointer<(real: Double, imag: Double)>) throws -> R
    ) rethrows -> R?
}

extension WaveformReadable {

    /// Iterates visible real values without requiring materialization.
    ///
    /// The default implementation uses a contiguous borrowed buffer when
    /// available and falls back to indexed lazy access otherwise.
    public func forEachRealValue(
        at point: Int,
        _ body: (Double) throws -> Void
    ) rethrows -> Bool {
        if let completed = try withRealValues(at: point, { values in
            for value in values {
                try body(value)
            }
            return true
        }) {
            return completed
        }

        guard point >= 0, point < pointCount else { return false }
        for variable in 0..<variableCount {
            guard let value = realValue(variable: variable, point: point) else {
                return false
            }
            try body(value)
        }
        return true
    }

    /// Iterates visible complex values without requiring materialization.
    ///
    /// The default implementation uses a contiguous borrowed buffer when
    /// available and falls back to indexed lazy access otherwise.
    public func forEachComplexValue(
        at point: Int,
        _ body: ((real: Double, imag: Double)) throws -> Void
    ) rethrows -> Bool {
        if let completed = try withComplexValues(at: point, { values in
            for value in values {
                try body(value)
            }
            return true
        }) {
            return completed
        }

        guard point >= 0, point < pointCount else { return false }
        for variable in 0..<variableCount {
            guard let value = complexValue(variable: variable, point: point) else {
                return false
            }
            try body(value)
        }
        return true
    }
}

/// A lazy complex-valued waveform series.
///
/// The view stores only a waveform source and a visible variable index.
/// Values are read on demand without materializing the full column.
public struct ComplexWaveformView: RandomAccessCollection, Sendable {

    public typealias Index = Int
    public typealias Element = (real: Double, imag: Double)

    /// The waveform name.
    public let name: String

    /// The unit of the values.
    public let unit: SIUnit

    private let source: any WaveformReadable
    private let variableIndex: Int

    public var startIndex: Int { 0 }

    public var endIndex: Int { source.pointCount }

    public init(
        source: any WaveformReadable,
        variableIndex: Int
    ) {
        self.source = source
        self.variableIndex = variableIndex
        if variableIndex >= 0, variableIndex < source.variableCount {
            self.name = source.variables[variableIndex].name
            self.unit = source.variables[variableIndex].unit
        } else {
            self.name = ""
            self.unit = .dimensionless
        }
    }

    public init(
        validatingSource source: any WaveformReadable,
        variableIndex: Int
    ) throws {
        guard variableIndex >= 0, variableIndex < source.variableCount else {
            throw WaveformAccessError.variableOutOfRange(
                variable: variableIndex,
                variableCount: source.variableCount
            )
        }
        self.source = source
        self.variableIndex = variableIndex
        self.name = source.variables[variableIndex].name
        self.unit = source.variables[variableIndex].unit
    }

    public subscript(position: Int) -> (real: Double, imag: Double) {
        guard position >= startIndex, position < endIndex,
              let value = source.complexValue(variable: variableIndex, point: position) else {
            return (real: .nan, imag: .nan)
        }
        return value
    }

    /// Returns a value without trapping on invalid or unreadable input.
    public func checkedValue(at point: Int) throws -> (real: Double, imag: Double) {
        guard variableIndex >= 0, variableIndex < source.variableCount else {
            throw WaveformAccessError.variableOutOfRange(
                variable: variableIndex,
                variableCount: source.variableCount
            )
        }
        guard point >= startIndex, point < endIndex else {
            throw WaveformAccessError.pointOutOfRange(point: point, pointCount: endIndex)
        }
        guard let value = source.complexValue(variable: variableIndex, point: point) else {
            throw WaveformAccessError.unreadableComplexValue(variable: variableIndex, point: point)
        }
        return value
    }

    /// Returns the sweep value at a point.
    public func sweepValue(at point: Int) -> Double {
        guard let value = source.sweepValue(at: point) else {
            return .nan
        }
        return value
    }

    /// Returns the sweep value without trapping on invalid or unreadable input.
    public func checkedSweepValue(at point: Int) throws -> Double {
        guard point >= startIndex, point < endIndex else {
            throw WaveformAccessError.pointOutOfRange(point: point, pointCount: endIndex)
        }
        guard let value = source.sweepValue(at: point) else {
            throw WaveformAccessError.unreadableSweepValue(point: point)
        }
        return value
    }

    /// Materializes the lazy series into an owning waveform.
    public func materialized() -> ComplexWaveform {
        var sweepValues: [Double] = []
        var values: [(real: Double, imag: Double)] = []
        sweepValues.reserveCapacity(count)
        values.reserveCapacity(count)

        for index in indices {
            sweepValues.append(sweepValue(at: index))
            values.append(self[index])
        }

        return ComplexWaveform(
            name: name,
            unit: unit,
            sweepValues: sweepValues,
            values: values
        )
    }

    /// Materializes the lazy series without trapping on unreadable input.
    public func checkedMaterialized() throws -> ComplexWaveform {
        var sweepValues: [Double] = []
        var values: [(real: Double, imag: Double)] = []
        sweepValues.reserveCapacity(count)
        values.reserveCapacity(count)

        for index in indices {
            sweepValues.append(try checkedSweepValue(at: index))
            values.append(try checkedValue(at: index))
        }

        return ComplexWaveform(
            name: name,
            unit: unit,
            sweepValues: sweepValues,
            values: values
        )
    }
}

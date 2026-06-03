import Foundation

/// Unified waveform data container for simulation results.
///
/// `WaveformData` provides a format-agnostic representation of simulation
/// waveforms that can be exported to various file formats (RAW, CSV, PSF).
public struct WaveformData: Sendable {

    /// Metadata about the simulation.
    public let metadata: SimulationMetadata

    /// The sweep variable (time, frequency, or sweep source).
    public let sweepVariable: VariableDescriptor

    /// The sweep values (x-axis data).
    public let sweepValues: [Double]

    /// Descriptors for all data variables.
    public let variables: [VariableDescriptor]

    /// Internal storage for the waveform data.
    private let storage: WaveformStorage

    /// Whether this waveform contains complex data.
    public var isComplex: Bool {
        storage.isComplex
    }

    /// The number of data points.
    public var pointCount: Int {
        storage.pointCount
    }

    /// The number of variables (excluding sweep).
    public var variableCount: Int {
        storage.variableCount
    }

    /// Creates a real-valued waveform.
    public init(
        metadata: SimulationMetadata,
        sweepVariable: VariableDescriptor,
        sweepValues: [Double],
        variables: [VariableDescriptor],
        realData: [[Double]]
    ) {
        self.metadata = metadata
        self.sweepVariable = sweepVariable
        self.sweepValues = sweepValues
        self.variables = variables
        self.storage = .real(realData)
    }

    /// Creates a real-valued waveform backed by row-major storage.
    ///
    /// `realRowMajorData[(point * variableCount) + variable]` stores the value
    /// for a point and variable. The array is retained with Swift copy-on-write
    /// semantics, so construction does not deep-copy when the caller passes an
    /// unmodified array buffer.
    public init(
        metadata: SimulationMetadata,
        sweepVariable: VariableDescriptor,
        sweepValues: [Double],
        variables: [VariableDescriptor],
        realRowMajorData: [Double],
        pointCount: Int,
        variableCount: Int
    ) {
        precondition(sweepValues.count == pointCount, "sweep value count must match point count")
        precondition(variables.count == variableCount, "variable descriptor count must match variable count")
        precondition(
            realRowMajorData.count == pointCount * variableCount,
            "row-major data count must equal pointCount * variableCount"
        )
        self.metadata = metadata
        self.sweepVariable = sweepVariable
        self.sweepValues = sweepValues
        self.variables = variables
        self.storage = .realRowMajor(
            values: realRowMajorData,
            pointCount: pointCount,
            variableCount: variableCount
        )
    }

    /// Creates a complex-valued waveform.
    public init(
        metadata: SimulationMetadata,
        sweepVariable: VariableDescriptor,
        sweepValues: [Double],
        variables: [VariableDescriptor],
        complexData: [[(real: Double, imag: Double)]]
    ) {
        self.metadata = metadata
        self.sweepVariable = sweepVariable
        self.sweepValues = sweepValues
        self.variables = variables
        self.storage = .complex(complexData)
    }

    // MARK: - Data Access

    /// Gets a real value for a variable at a point index.
    ///
    /// For complex data, returns the real part.
    public func realValue(variable: Int, point: Int) -> Double? {
        storage.realValue(point: point, variable: variable)
    }

    /// Gets a complex value for a variable at a point index.
    ///
    /// For real data, returns the value with zero imaginary part.
    public func complexValue(variable: Int, point: Int) -> (real: Double, imag: Double)? {
        storage.complexValue(point: point, variable: variable)
    }

    /// Provides a real-valued point as a borrowed contiguous buffer.
    ///
    /// The buffer is valid only for the duration of `body`. This avoids
    /// materializing a per-point `[Double]` when storage is already contiguous.
    public func withRealValues<R>(
        at point: Int,
        _ body: (UnsafeBufferPointer<Double>) throws -> R
    ) rethrows -> R? {
        try storage.withRealValues(point: point, body)
    }

    /// Provides the full row-major real buffer when this waveform is backed by
    /// contiguous row-major storage.
    public func withRealRowMajorValues<R>(
        _ body: (UnsafeBufferPointer<Double>, Int, Int) throws -> R
    ) rethrows -> R? {
        try storage.withRealRowMajorValues(body)
    }

    /// Provides a complex-valued point as a borrowed contiguous buffer.
    ///
    /// The buffer is valid only for the duration of `body`.
    public func withComplexValues<R>(
        at point: Int,
        _ body: (UnsafeBufferPointer<(real: Double, imag: Double)>) throws -> R
    ) rethrows -> R? {
        try storage.withComplexValues(point: point, body)
    }

    /// Gets the magnitude of a complex value.
    public func magnitude(variable: Int, point: Int) -> Double? {
        guard let (r, i) = complexValue(variable: variable, point: point) else { return nil }
        return (r * r + i * i).squareRoot()
    }

    /// Gets the phase of a complex value in radians.
    public func phase(variable: Int, point: Int) -> Double? {
        guard let (r, i) = complexValue(variable: variable, point: point) else { return nil }
        return atan2(i, r)
    }

    /// Gets the magnitude in decibels.
    public func magnitudeDB(variable: Int, point: Int) -> Double? {
        guard let mag = magnitude(variable: variable, point: point) else { return nil }
        return 20.0 * log10(max(mag, 1e-300))
    }

    /// Gets the phase in degrees.
    public func phaseDegrees(variable: Int, point: Int) -> Double? {
        guard let ph = phase(variable: variable, point: point) else { return nil }
        return ph * 180.0 / .pi
    }

    // MARK: - Waveform Extraction

    /// Returns a real waveform for the named variable.
    public func realWaveform(named name: String) -> RealWaveform? {
        realSeries(named: name)?.materialized()
    }

    /// Returns a real waveform at the given variable index.
    public func realWaveform(at index: Int) -> RealWaveform? {
        realSeries(at: index)?.materialized()
    }

    /// Returns a complex waveform for the named variable.
    public func complexWaveform(named name: String) -> ComplexWaveform? {
        complexSeries(named: name)?.materialized()
    }

    /// Returns a complex waveform at the given variable index.
    public func complexWaveform(at index: Int) -> ComplexWaveform? {
        complexSeries(at: index)?.materialized()
    }

    /// Finds a variable descriptor by name.
    public func variable(named name: String) -> VariableDescriptor? {
        variables.first { $0.name == name }
    }

    /// Finds the index of a variable by name.
    public func variableIndex(named name: String) -> Int? {
        variables.firstIndex { $0.name == name }
    }

    // MARK: - Bulk Data Access

    /// Returns all real data as a 2D array [point][variable].
    ///
    /// Returns nil if this waveform contains complex data.
    public var allRealData: [[Double]]? {
        storage.materializedRealRows
    }

    /// Returns all complex data as a 2D array [point][(real, imag)].
    ///
    /// Returns nil if this waveform contains only real data.
    public var allComplexData: [[(real: Double, imag: Double)]]? {
        switch storage {
        case .real, .realRowMajor:
            return nil
        case .complex(let data):
            return data
        }
    }

    /// Returns real row-major storage when this waveform contains real data.
    ///
    /// For row-major-backed waveforms this returns the existing storage with
    /// Swift copy-on-write semantics. For nested-array-backed waveforms it
    /// materializes a flat copy.
    public var realRowMajorValues: (values: [Double], pointCount: Int, variableCount: Int)? {
        storage.realRowMajorValues
    }

    /// Returns all real data, converting complex to real part if needed.
    public var allRealValues: [[Double]] {
        switch storage {
        case .real(let data):
            return data
        case .realRowMajor:
            return storage.materializedRealRows ?? []
        case .complex(let data):
            return data.map { $0.map { $0.real } }
        }
    }

    /// Returns all complex data, converting real to complex if needed.
    public var allComplexValues: [[(real: Double, imag: Double)]] {
        switch storage {
        case .real(let data):
            return data.map { $0.map { (real: $0, imag: 0.0) } }
        case .realRowMajor:
            return (storage.materializedRealRows ?? []).map { row in
                row.map { (real: $0, imag: 0.0) }
            }
        case .complex(let data):
            return data
        }
    }
}

// MARK: - Waveform Types

/// A real-valued waveform with sweep values.
public struct RealWaveform: Sendable {

    /// The waveform name.
    public let name: String

    /// The unit of the values.
    public let unit: SIUnit

    /// The sweep (x-axis) values.
    public let sweepValues: [Double]

    /// The waveform (y-axis) values.
    public let values: [Double]

    public init(
        name: String,
        unit: SIUnit,
        sweepValues: [Double],
        values: [Double]
    ) {
        self.name = name
        self.unit = unit
        self.sweepValues = sweepValues
        self.values = values
    }

    /// Returns the value at the given sweep index.
    public subscript(index: Int) -> Double {
        values[index]
    }

    /// The number of points.
    public var count: Int {
        values.count
    }

    /// Returns (sweep, value) pairs.
    public var points: [(sweep: Double, value: Double)] {
        zip(sweepValues, values).map { ($0, $1) }
    }
}

/// A complex-valued waveform with sweep values.
public struct ComplexWaveform: Sendable {

    /// The waveform name.
    public let name: String

    /// The unit of the values.
    public let unit: SIUnit

    /// The sweep (x-axis) values.
    public let sweepValues: [Double]

    /// The complex (y-axis) values.
    public let values: [(real: Double, imag: Double)]

    public init(
        name: String,
        unit: SIUnit,
        sweepValues: [Double],
        values: [(real: Double, imag: Double)]
    ) {
        self.name = name
        self.unit = unit
        self.sweepValues = sweepValues
        self.values = values
    }

    /// Returns the complex value at the given sweep index.
    public subscript(index: Int) -> (real: Double, imag: Double) {
        values[index]
    }

    /// The number of points.
    public var count: Int {
        values.count
    }

    /// Returns the magnitude waveform.
    public var magnitude: RealWaveform {
        let mags = values.map { ($0.real * $0.real + $0.imag * $0.imag).squareRoot() }
        return RealWaveform(
            name: "\(name)_mag",
            unit: unit,
            sweepValues: sweepValues,
            values: mags
        )
    }

    /// Returns the magnitude in dB waveform.
    public var magnitudeDB: RealWaveform {
        let dbs = values.map { 20.0 * log10(max(($0.real * $0.real + $0.imag * $0.imag).squareRoot(), 1e-300)) }
        return RealWaveform(
            name: "\(name)_dB",
            unit: .decibel,
            sweepValues: sweepValues,
            values: dbs
        )
    }

    /// Returns the phase waveform in degrees.
    public var phaseDegrees: RealWaveform {
        let phases = values.map { atan2($0.imag, $0.real) * 180.0 / .pi }
        return RealWaveform(
            name: "\(name)_phase",
            unit: .degree,
            sweepValues: sweepValues,
            values: phases
        )
    }
}

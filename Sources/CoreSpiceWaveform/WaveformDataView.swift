/// A lazy read-only projection over a waveform source.
///
/// `WaveformDataView` owns no waveform samples. It stores only point and
/// variable index projections and reads values from the base waveform on
/// demand. Contiguous projections can still expose borrowed point buffers.
public struct WaveformDataView: WaveformReadable {

    /// The backing waveform source.
    public let base: any WaveformReadable

    /// Prevalidated visible point and variable mapping.
    public let projection: WaveformProjection

    /// Visible base point indices. `nil` means identity projection.
    public var pointIndices: [Int]? {
        projection.pointIndices
    }

    /// Visible base variable indices. `nil` means identity projection.
    public var variableIndices: [Int]? {
        projection.variableIndices
    }

    /// Metadata describing the visible projection.
    public let metadata: SimulationMetadata

    /// Visible variable descriptors with visible indices.
    public let variables: [VariableDescriptor]

    public var sweepVariable: VariableDescriptor {
        base.sweepVariable
    }

    public var isComplex: Bool {
        base.isComplex
    }

    public var pointCount: Int {
        projection.pointCount
    }

    public var variableCount: Int {
        variables.count
    }

    public init(
        base: any WaveformReadable,
        pointIndices: [Int]? = nil,
        variableIndices: [Int]? = nil
    ) {
        self.init(
            base: base,
            layout: WaveformViewLayout(
                base: base,
                pointIndices: pointIndices,
                variableIndices: variableIndices
            )
        )
    }

    public init(
        validatingBase base: any WaveformReadable,
        pointIndices: [Int]? = nil,
        variableIndices: [Int]? = nil
    ) throws {
        try self.init(
            validatingBase: base,
            layout: WaveformViewLayout(
                validatingBase: base,
                pointIndices: pointIndices,
                variableIndices: variableIndices
            )
        )
    }

    public init(
        base: any WaveformReadable,
        projection: WaveformProjection
    ) {
        self.init(base: base, layout: WaveformViewLayout(base: base, projection: projection))
    }

    public init(
        validatingBase base: any WaveformReadable,
        projection: WaveformProjection
    ) throws {
        try self.init(
            validatingBase: base,
            layout: WaveformViewLayout(validatingBase: base, projection: projection)
        )
    }

    public init(
        base: any WaveformReadable,
        layout: WaveformViewLayout
    ) {
        let resolvedLayout: WaveformViewLayout
        if layout.projection.basePointCount == base.pointCount,
           layout.projection.baseVariableCount == base.variableCount {
            resolvedLayout = layout
        } else {
            resolvedLayout = WaveformViewLayout(base: base)
        }

        self.init(uncheckedBase: base, layout: resolvedLayout)
    }

    public init(
        validatingBase base: any WaveformReadable,
        layout: WaveformViewLayout
    ) throws {
        guard layout.projection.basePointCount == base.pointCount else {
            throw WaveformValidationError.projectionPointShapeMismatch(
                projectionPointCount: layout.projection.basePointCount,
                basePointCount: base.pointCount
            )
        }
        guard layout.projection.baseVariableCount == base.variableCount else {
            throw WaveformValidationError.projectionVariableShapeMismatch(
                projectionVariableCount: layout.projection.baseVariableCount,
                baseVariableCount: base.variableCount
            )
        }

        self.init(uncheckedBase: base, layout: layout)
    }

    private init(
        uncheckedBase base: any WaveformReadable,
        layout: WaveformViewLayout
    ) {
        self.base = base
        self.projection = layout.projection
        self.variables = layout.variables
        self.metadata = layout.metadata
    }

    /// Returns a materialized waveform for APIs that explicitly need ownership.
    public func materialized() throws -> WaveformData {
        try checkedMaterialized()
    }

    /// Returns a materialized waveform without trapping on unreadable input.
    public func checkedMaterialized() throws -> WaveformData {
        let sweepValues = try checkedMaterializedSweepValues()

        if isComplex {
            var rows: [[(real: Double, imag: Double)]] = []
            rows.reserveCapacity(pointCount)
            for point in 0..<pointCount {
                var row: [(real: Double, imag: Double)] = []
                row.reserveCapacity(variableCount)
                for variable in 0..<variableCount {
                    guard let value = complexValue(variable: variable, point: point) else {
                        throw WaveformAccessError.unreadableComplexValue(variable: variable, point: point)
                    }
                    row.append(value)
                }
                rows.append(row)
            }
            return WaveformData(
                metadata: metadata,
                sweepVariable: sweepVariable,
                sweepValues: sweepValues,
                variables: variables,
                complexData: rows
            )
        }

        var values: [Double] = []
        values.reserveCapacity(pointCount * variableCount)
        for point in 0..<pointCount {
            for variable in 0..<variableCount {
                guard let value = realValue(variable: variable, point: point) else {
                    throw WaveformAccessError.unreadableRealValue(variable: variable, point: point)
                }
                values.append(value)
            }
        }

        return try WaveformData(
            validatingMetadata: metadata,
            sweepVariable: sweepVariable,
            sweepValues: sweepValues,
            variables: variables,
            realRowMajorData: values,
            pointCount: pointCount,
            variableCount: variableCount
        )
    }

    public func sweepValue(at point: Int) -> Double? {
        guard let basePoint = basePointIndex(for: point) else { return nil }
        return base.sweepValue(at: basePoint)
    }

    public func withSweepValues<R>(
        _ body: (UnsafeBufferPointer<Double>) throws -> R
    ) rethrows -> R? {
        guard projection.pointIndices == nil else {
            return nil
        }
        return try base.withSweepValues(body)
    }

    public func realValue(variable: Int, point: Int) -> Double? {
        guard let basePoint = basePointIndex(for: point),
              let baseVariable = baseVariableIndex(for: variable) else {
            return nil
        }
        return base.realValue(variable: baseVariable, point: basePoint)
    }

    public func complexValue(variable: Int, point: Int) -> (real: Double, imag: Double)? {
        guard let basePoint = basePointIndex(for: point),
              let baseVariable = baseVariableIndex(for: variable) else {
            return nil
        }
        return base.complexValue(variable: baseVariable, point: basePoint)
    }

    public func withRealValues<R>(
        at point: Int,
        _ body: (UnsafeBufferPointer<Double>) throws -> R
    ) rethrows -> R? {
        guard let basePoint = basePointIndex(for: point),
              let variableSlice = projection.contiguousVariableSlice else {
            return nil
        }

        return try base.withRealValues(at: basePoint) { values in
            guard !variableSlice.isEmpty else {
                return try body(UnsafeBufferPointer(start: nil, count: 0))
            }
            guard let baseAddress = values.baseAddress else {
                return try body(UnsafeBufferPointer(start: nil, count: 0))
            }
            return try body(
                UnsafeBufferPointer(
                    start: baseAddress + variableSlice.lowerBound,
                    count: variableSlice.count
                )
            )
        }
    }

    public func withComplexValues<R>(
        at point: Int,
        _ body: (UnsafeBufferPointer<(real: Double, imag: Double)>) throws -> R
    ) rethrows -> R? {
        guard let basePoint = basePointIndex(for: point),
              let variableSlice = projection.contiguousVariableSlice else {
            return nil
        }

        return try base.withComplexValues(at: basePoint) { values in
            guard !variableSlice.isEmpty else {
                return try body(UnsafeBufferPointer(start: nil, count: 0))
            }
            guard let baseAddress = values.baseAddress else {
                return try body(UnsafeBufferPointer(start: nil, count: 0))
            }
            return try body(
                UnsafeBufferPointer(
                    start: baseAddress + variableSlice.lowerBound,
                    count: variableSlice.count
                )
            )
        }
    }

    public func withRealRowMajorValues<R>(
        _ body: (UnsafeBufferPointer<Double>, Int, Int) throws -> R
    ) rethrows -> R? {
        guard projection.pointIndices == nil,
              projection.contiguousVariableSlice == 0..<base.variableCount else {
            return nil
        }
        return try base.withRealRowMajorValues(body)
    }

    public func withRealRowMajorBuffer<R>(
        _ body: (RealRowMajorBuffer) throws -> R
    ) rethrows -> R? {
        guard let pointPattern = projection.regularPointPattern,
              let variableSlice = projection.contiguousVariableSlice else {
            return nil
        }
        return try base.withRealRowMajorBuffer { source in
            try body(
                RealRowMajorBuffer(
                    values: source.values,
                    pointCount: pointCount,
                    variableCount: variableSlice.count,
                    rowStride: source.rowStride * pointPattern.stride,
                    startOffset: source.startOffset
                        + (pointPattern.start * source.rowStride)
                        + variableSlice.lowerBound
                )
            )
        }
    }

    private func checkedMaterializedSweepValues() throws -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(pointCount)
        for point in 0..<pointCount {
            guard let value = sweepValue(at: point) else {
                throw WaveformAccessError.unreadableSweepValue(point: point)
            }
            values.append(value)
        }
        return values
    }

    private func basePointIndex(for point: Int) -> Int? {
        projection.basePointIndex(for: point)
    }

    private func baseVariableIndex(for variable: Int) -> Int? {
        projection.baseVariableIndex(for: variable)
    }
}

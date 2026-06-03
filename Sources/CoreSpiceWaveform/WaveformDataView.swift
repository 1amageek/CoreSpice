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
        base: any WaveformReadable,
        projection: WaveformProjection
    ) {
        self.init(base: base, layout: WaveformViewLayout(base: base, projection: projection))
    }

    public init(
        base: any WaveformReadable,
        layout: WaveformViewLayout
    ) {
        precondition(layout.projection.basePointCount == base.pointCount, "layout point shape must match base waveform")
        precondition(layout.projection.baseVariableCount == base.variableCount, "layout variable shape must match base waveform")

        self.base = base
        self.projection = layout.projection
        self.variables = layout.variables
        self.metadata = layout.metadata
    }

    /// Returns a materialized waveform for APIs that explicitly need ownership.
    public func materialized() -> WaveformData {
        if isComplex {
            var rows: [[(real: Double, imag: Double)]] = []
            rows.reserveCapacity(pointCount)
            for point in 0..<pointCount {
                var row: [(real: Double, imag: Double)] = []
                row.reserveCapacity(variableCount)
                let completed = forEachComplexValue(at: point) { value in
                    row.append(value)
                }
                precondition(completed, "complex waveform view must be readable")
                rows.append(row)
            }
            return WaveformData(
                metadata: metadata,
                sweepVariable: sweepVariable,
                sweepValues: materializedSweepValues(),
                variables: variables,
                complexData: rows
            )
        }

        if let materialized = materializedFromRealRowMajorStorage() {
            return materialized
        }

        let totalCount = pointCount * variableCount
        let values = Array<Double>(unsafeUninitializedCapacity: totalCount) { output, initializedCount in
            initializedCount = 0
            guard let outputBase = output.baseAddress else {
                precondition(totalCount == 0, "non-empty waveform destination must have a base address")
                return
            }

            for point in 0..<pointCount {
                let completed = forEachRealValue(at: point) { value in
                    outputBase.advanced(by: initializedCount).initialize(to: value)
                    initializedCount += 1
                }
                precondition(completed, "real waveform view must be readable")
            }
            precondition(initializedCount == totalCount, "real waveform view must materialize all values")
        }
        return WaveformData(
            metadata: metadata,
            sweepVariable: sweepVariable,
            sweepValues: materializedSweepValues(),
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
                preconditionFailure("non-empty real point buffer must have a base address")
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
                preconditionFailure("non-empty complex point buffer must have a base address")
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

    private func materializedSweepValues() -> [Double] {
        if let values = materializedSweepValuesFromStorage() {
            return values
        }

        var values: [Double] = []
        values.reserveCapacity(pointCount)
        for point in 0..<pointCount {
            guard let value = sweepValue(at: point) else {
                preconditionFailure("waveform view sweep value must be readable")
            }
            values.append(value)
        }
        return values
    }

    private func materializedSweepValuesFromStorage() -> [Double]? {
        base.withSweepValues { sourceValues in
            Array<Double>(unsafeUninitializedCapacity: pointCount) { output, initializedCount in
                initializedCount = pointCount
                guard pointCount > 0 else { return }
                guard let sourceBase = sourceValues.baseAddress else {
                    preconditionFailure("non-empty sweep buffer must have a base address")
                }
                guard let outputBase = output.baseAddress else {
                    preconditionFailure("non-empty sweep destination must have a base address")
                }

                if let pointPattern = projection.regularPointPattern {
                    if pointPattern.stride == 1 {
                        outputBase.initialize(
                            from: sourceBase.advanced(by: pointPattern.start),
                            count: pointCount
                        )
                        return
                    }

                    var sourcePoint = pointPattern.start
                    for point in 0..<pointCount {
                        outputBase.advanced(by: point).initialize(to: sourceBase[sourcePoint])
                        sourcePoint += pointPattern.stride
                    }
                    return
                }

                for point in 0..<pointCount {
                    guard let basePoint = projection.basePointIndex(for: point) else {
                        preconditionFailure("waveform view point index out of range")
                    }
                    outputBase.advanced(by: point).initialize(to: sourceBase[basePoint])
                }
            }
        }
    }

    private func basePointIndex(for point: Int) -> Int? {
        projection.basePointIndex(for: point)
    }

    private func baseVariableIndex(for variable: Int) -> Int? {
        projection.baseVariableIndex(for: variable)
    }

    private func materializedFromRealRowMajorStorage() -> WaveformData? {
        withRealRowMajorBuffer { source in
            let totalCount = pointCount * variableCount
            let values = Array<Double>(unsafeUninitializedCapacity: totalCount) { output, initializedCount in
                initializedCount = totalCount
                fillRealRowMajorBuffer(source, destination: output)
            }

            return WaveformData(
                metadata: metadata,
                sweepVariable: sweepVariable,
                sweepValues: materializedSweepValues(),
                variables: variables,
                realRowMajorData: values,
                pointCount: pointCount,
                variableCount: variableCount
            )
        }
    }

    private func fillRealRowMajorBuffer(
        _ source: RealRowMajorBuffer,
        destination: UnsafeMutableBufferPointer<Double>
    ) {
        guard destination.count > 0 else { return }
        guard source.variableCount > 0 else { return }
        guard let sourceBase = source.values.baseAddress else {
            preconditionFailure("non-empty row-major buffer must have a base address")
        }
        guard let outputBase = destination.baseAddress else {
            preconditionFailure("non-empty destination buffer must have a base address")
        }

        var outputOffset = 0
        for point in 0..<source.pointCount {
            outputBase.advanced(by: outputOffset).initialize(
                from: sourceBase.advanced(by: source.startOffset + (point * source.rowStride)),
                count: source.variableCount
            )
            outputOffset += source.variableCount
        }
    }
}

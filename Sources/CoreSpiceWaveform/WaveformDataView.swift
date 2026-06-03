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

        var values: [Double] = []
        values.reserveCapacity(pointCount * variableCount)
        for point in 0..<pointCount {
            let completed = forEachRealValue(at: point) { value in
                values.append(value)
            }
            precondition(completed, "real waveform view must be readable")
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
            var values = Array(repeating: 0.0, count: pointCount)
            guard !values.isEmpty else { return values }
            guard let sourceBase = sourceValues.baseAddress else {
                preconditionFailure("non-empty sweep buffer must have a base address")
            }

            values.withUnsafeMutableBufferPointer { output in
                guard let outputBase = output.baseAddress else {
                    preconditionFailure("non-empty sweep destination must have a base address")
                }

                if let pointPattern = projection.regularPointPattern {
                    var sourcePoint = pointPattern.start
                    for point in 0..<pointCount {
                        outputBase[point] = sourceBase[sourcePoint]
                        sourcePoint += pointPattern.stride
                    }
                    return
                }

                for point in 0..<pointCount {
                    guard let basePoint = projection.basePointIndex(for: point) else {
                        preconditionFailure("waveform view point index out of range")
                    }
                    outputBase[point] = sourceBase[basePoint]
                }
            }
            return values
        }
    }

    private func basePointIndex(for point: Int) -> Int? {
        projection.basePointIndex(for: point)
    }

    private func baseVariableIndex(for variable: Int) -> Int? {
        projection.baseVariableIndex(for: variable)
    }

    private func materializedFromRealRowMajorStorage() -> WaveformData? {
        guard let variableSlice = projection.contiguousVariableSlice else {
            return nil
        }
        return base.withRealRowMajorValues { sourceValues, _, sourceVariableCount in
            let totalCount = pointCount * variableCount
            var values = Array(repeating: 0.0, count: totalCount)
            fillRealRowMajorProjection(
                sourceValues: sourceValues,
                sourceVariableCount: sourceVariableCount,
                variableSlice: variableSlice,
                destination: &values
            )

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

    private func fillRealRowMajorProjection(
        sourceValues: UnsafeBufferPointer<Double>,
        sourceVariableCount: Int,
        variableSlice: Range<Int>,
        destination: inout [Double]
    ) {
        guard !destination.isEmpty else { return }
        guard !variableSlice.isEmpty else { return }
        guard let sourceBase = sourceValues.baseAddress else {
            preconditionFailure("non-empty row-major buffer must have a base address")
        }

        destination.withUnsafeMutableBufferPointer { output in
            guard let outputBase = output.baseAddress else {
                preconditionFailure("non-empty destination buffer must have a base address")
            }

            var outputOffset = 0
            if let pointPattern = projection.regularPointPattern {
                var sourcePoint = pointPattern.start
                for _ in 0..<pointCount {
                    copyVariables(
                        sourceBase: sourceBase,
                        sourceOffset: (sourcePoint * sourceVariableCount) + variableSlice.lowerBound,
                        outputBase: outputBase,
                        outputOffset: outputOffset,
                        count: variableSlice.count
                    )
                    sourcePoint += pointPattern.stride
                    outputOffset += variableSlice.count
                }
                return
            }

            for point in 0..<pointCount {
                guard let basePoint = projection.basePointIndex(for: point) else {
                    preconditionFailure("waveform view point index out of range")
                }
                copyVariables(
                    sourceBase: sourceBase,
                    sourceOffset: (basePoint * sourceVariableCount) + variableSlice.lowerBound,
                    outputBase: outputBase,
                    outputOffset: outputOffset,
                    count: variableSlice.count
                )
                outputOffset += variableSlice.count
            }
        }
    }

    private func copyVariables(
        sourceBase: UnsafePointer<Double>,
        sourceOffset: Int,
        outputBase: UnsafeMutablePointer<Double>,
        outputOffset: Int,
        count: Int
    ) {
        for offset in 0..<count {
            outputBase[outputOffset + offset] = sourceBase[sourceOffset + offset]
        }
    }
}

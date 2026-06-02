/// A lazy read-only projection over a waveform source.
///
/// `WaveformDataView` owns no waveform samples. It stores only point and
/// variable index projections and reads values from the base waveform on
/// demand. Contiguous projections can still expose borrowed point buffers.
public struct WaveformDataView: WaveformReadable {

    /// The backing waveform source.
    public let base: any WaveformReadable

    /// Visible base point indices. `nil` means identity projection.
    public let pointIndices: [Int]?

    /// Visible base variable indices. `nil` means identity projection.
    public let variableIndices: [Int]?

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
        pointIndices?.count ?? base.pointCount
    }

    public var variableCount: Int {
        variables.count
    }

    public init(
        base: any WaveformReadable,
        pointIndices: [Int]? = nil,
        variableIndices: [Int]? = nil
    ) {
        if let pointIndices {
            precondition(pointIndices.allSatisfy { $0 >= 0 && $0 < base.pointCount })
        }
        if let variableIndices {
            precondition(variableIndices.allSatisfy { $0 >= 0 && $0 < base.variableCount })
        }

        self.base = base
        self.pointIndices = Self.identityOrNil(pointIndices, count: base.pointCount)
        self.variableIndices = Self.identityOrNil(variableIndices, count: base.variableCount)
        let visiblePointCount = self.pointIndices?.count ?? base.pointCount

        let sourceVariables: [VariableDescriptor]
        if let variableIndices = self.variableIndices {
            sourceVariables = variableIndices.map { base.variables[$0] }
        } else {
            sourceVariables = base.variables
        }

        self.variables = sourceVariables.enumerated().map { visibleIndex, source in
            VariableDescriptor(
                name: source.name,
                unit: source.unit,
                type: source.type,
                index: visibleIndex
            )
        }

        self.metadata = SimulationMetadata(
            title: base.metadata.title,
            analysisType: base.metadata.analysisType,
            pointCount: visiblePointCount,
            variableCount: self.variables.count,
            isComplex: base.metadata.isComplex
        )
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
              let variableSlice = contiguousVariableSlice() else {
            return nil
        }

        return try base.withRealValues(at: basePoint) { values in
            guard variableSlice.count > 0 else {
                return try body(UnsafeBufferPointer(start: nil, count: 0))
            }
            guard let baseAddress = values.baseAddress else {
                preconditionFailure("non-empty real point buffer must have a base address")
            }
            return try body(
                UnsafeBufferPointer(
                    start: baseAddress + variableSlice.start,
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
              let variableSlice = contiguousVariableSlice() else {
            return nil
        }

        return try base.withComplexValues(at: basePoint) { values in
            guard variableSlice.count > 0 else {
                return try body(UnsafeBufferPointer(start: nil, count: 0))
            }
            guard let baseAddress = values.baseAddress else {
                preconditionFailure("non-empty complex point buffer must have a base address")
            }
            return try body(
                UnsafeBufferPointer(
                    start: baseAddress + variableSlice.start,
                    count: variableSlice.count
                )
            )
        }
    }

    private func materializedSweepValues() -> [Double] {
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

    private func basePointIndex(for point: Int) -> Int? {
        guard point >= 0, point < pointCount else { return nil }
        guard let pointIndices else { return point }
        return pointIndices[point]
    }

    private func baseVariableIndex(for variable: Int) -> Int? {
        guard variable >= 0, variable < variableCount else { return nil }
        guard let variableIndices else { return variable }
        return variableIndices[variable]
    }

    private func contiguousVariableSlice() -> (start: Int, count: Int)? {
        guard let variableIndices else {
            return (start: 0, count: base.variableCount)
        }
        guard let first = variableIndices.first else {
            return (start: 0, count: 0)
        }
        for offset in 0..<variableIndices.count {
            if variableIndices[offset] != first + offset {
                return nil
            }
        }
        return (start: first, count: variableIndices.count)
    }

    private static func identityOrNil(_ indices: [Int]?, count: Int) -> [Int]? {
        guard let indices else { return nil }
        if indices.elementsEqual(0..<count) {
            return nil
        }
        return indices
    }
}

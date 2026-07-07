/// Precomputed visible descriptors and metadata for a waveform view.
///
/// Reusing this layout avoids rebuilding projected variable descriptors and
/// metadata when many views share the same base waveform shape and projection.
public struct WaveformViewLayout: Sendable {
    public let projection: WaveformProjection
    public let metadata: SimulationMetadata
    public let variables: [VariableDescriptor]

    public init(
        base: any WaveformReadable,
        pointIndices: [Int]? = nil,
        variableIndices: [Int]? = nil
    ) {
        self.init(
            base: base,
            projection: WaveformProjection(
                basePointCount: base.pointCount,
                baseVariableCount: base.variableCount,
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
            projection: WaveformProjection(
                validatingBasePointCount: base.pointCount,
                baseVariableCount: base.variableCount,
                pointIndices: pointIndices,
                variableIndices: variableIndices
            )
        )
    }

    public init(
        base: any WaveformReadable,
        projection: WaveformProjection
    ) {
        let resolvedProjection: WaveformProjection
        if projection.basePointCount == base.pointCount,
           projection.baseVariableCount == base.variableCount {
            resolvedProjection = projection
        } else {
            resolvedProjection = WaveformProjection(
                basePointCount: base.pointCount,
                baseVariableCount: base.variableCount
            )
        }

        self.init(uncheckedBase: base, projection: resolvedProjection)
    }

    public init(
        validatingBase base: any WaveformReadable,
        projection: WaveformProjection
    ) throws {
        guard projection.basePointCount == base.pointCount else {
            throw WaveformValidationError.projectionPointShapeMismatch(
                projectionPointCount: projection.basePointCount,
                basePointCount: base.pointCount
            )
        }
        guard projection.baseVariableCount == base.variableCount else {
            throw WaveformValidationError.projectionVariableShapeMismatch(
                projectionVariableCount: projection.baseVariableCount,
                baseVariableCount: base.variableCount
            )
        }

        self.init(uncheckedBase: base, projection: projection)
    }

    private init(
        uncheckedBase base: any WaveformReadable,
        projection: WaveformProjection
    ) {
        let sourceVariables: [VariableDescriptor]
        if let variableIndices = projection.variableIndices {
            sourceVariables = variableIndices.map { base.variables[$0] }
        } else {
            sourceVariables = base.variables
        }

        let variables = sourceVariables.enumerated().map { visibleIndex, source in
            VariableDescriptor(
                name: source.name,
                unit: source.unit,
                type: source.type,
                index: visibleIndex
            )
        }

        self.projection = projection
        self.variables = variables
        self.metadata = SimulationMetadata(
            title: base.metadata.title,
            date: base.metadata.date,
            tool: base.metadata.tool,
            toolVersion: base.metadata.toolVersion,
            analysisType: base.metadata.analysisType,
            temperature: base.metadata.temperature,
            pointCount: projection.pointCount,
            variableCount: variables.count,
            isComplex: base.metadata.isComplex,
            options: base.metadata.options
        )
    }
}

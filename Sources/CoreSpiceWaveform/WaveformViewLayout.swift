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
        base: any WaveformReadable,
        projection: WaveformProjection
    ) {
        precondition(projection.basePointCount == base.pointCount, "projection point shape must match base waveform")
        precondition(projection.baseVariableCount == base.variableCount, "projection variable shape must match base waveform")

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

import CircuiteFoundation

public struct CoreSpiceSimulationEngineAdapter: CoreSpiceSimulationEngine {
    private let executor: any CoreSpiceSimulationExecuting
    private let producer: ProducerIdentity
    private let supportingTools: [ProducerIdentity]

    public init(
        executor: any CoreSpiceSimulationExecuting,
        producer: ProducerIdentity,
        supportingTools: [ProducerIdentity] = []
    ) {
        self.executor = executor
        self.producer = producer
        self.supportingTools = supportingTools
    }

    public func execute(
        _ request: CoreSpiceSimulationRequest
    ) async throws -> CoreSpiceSimulationResult {
        try Task.checkCancellation()
        let execution = try await executor.execute(request)
        try Task.checkCancellation()

        let provenance = try ExecutionProvenance(
            producer: producer,
            supportingTools: supportingTools,
            inputs: request.inputs,
            configurationDigest: request.configurationDigest,
            designRevision: request.designRevision,
            randomSeed: request.randomSeed,
            startedAt: execution.startedAt,
            completedAt: execution.completedAt
        )

        return CoreSpiceSimulationResult(
            artifacts: execution.artifacts,
            diagnostics: execution.diagnostics,
            provenance: provenance
        )
    }
}

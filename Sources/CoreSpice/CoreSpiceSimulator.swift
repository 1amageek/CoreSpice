import CircuiteFoundation

public struct CoreSpiceSimulator: CoreSpiceSimulating {
    private let backend: any CoreSpiceSimulationBackend
    private let producer: ProducerIdentity
    private let supportingTools: [ProducerIdentity]

    public init(
        backend: any CoreSpiceSimulationBackend,
        producer: ProducerIdentity,
        supportingTools: [ProducerIdentity] = []
    ) {
        self.backend = backend
        self.producer = producer
        self.supportingTools = supportingTools
    }

    public func execute(
        _ request: CoreSpiceSimulationRequest
    ) async throws -> CoreSpiceSimulationResult {
        try Task.checkCancellation()
        let execution = try await backend.execute(request)
        try Task.checkCancellation()

        let provenance = try ExecutionProvenance(
            producer: producer,
            supportingTools: supportingTools,
            inputs: request.inputs,
            invocation: execution.invocation,
            environment: execution.environment,
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

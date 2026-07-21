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

        return try CoreSpiceSimulationResult(
            request: request,
            execution: execution,
            producer: producer,
            supportingTools: supportingTools
        )
    }
}

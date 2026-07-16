public protocol CoreSpiceSimulationBackend: Sendable {
    func execute(
        _ request: CoreSpiceSimulationRequest
    ) async throws -> CoreSpiceSimulationExecution
}

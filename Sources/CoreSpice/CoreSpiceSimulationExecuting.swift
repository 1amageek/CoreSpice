public protocol CoreSpiceSimulationExecuting: Sendable {
    func execute(
        _ request: CoreSpiceSimulationRequest
    ) async throws -> CoreSpiceSimulationExecution
}

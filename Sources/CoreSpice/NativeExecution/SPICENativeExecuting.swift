import CoreSpiceEvent

public protocol SPICENativeExecuting: Sendable {
    func execute(_ prepared: PreparedNativeSPICESimulation, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> SPICENativeSimulationOutput
}

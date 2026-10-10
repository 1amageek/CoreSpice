import CoreSpiceEvent

public protocol SPICENativeExecuting: Sendable {
    func execute(_ prepared: consuming PreparedNativeSPICESimulation, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> SPICENativeSimulationOutput
}

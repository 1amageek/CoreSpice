import CoreSpiceAnalysis
import CoreSpiceEvent

public protocol SPICENativeExecuting: Sendable {
    func execute(_ prepared: consuming PreparedNativeSPICESimulation, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> SPICENativeSimulationOutput
    func execute(_ prepared: consuming PreparedNativeSPICESimulation, cancellation: CancellationToken,
                 executionResources: AnalysisExecutionResources?)
        async throws(SPICENativeExecutionError) -> SPICENativeSimulationOutput
}

extension SPICENativeExecuting {
    public func execute(_ prepared: consuming PreparedNativeSPICESimulation, cancellation: CancellationToken,
                        executionResources: AnalysisExecutionResources?)
        async throws(SPICENativeExecutionError) -> SPICENativeSimulationOutput {
        guard executionResources == nil else {
            throw NativeCircuitExecution.failure(SPICENativeExecutionError.unsupportedCapability(
                "Executor does not implement invocation-wide numerical admission"), closing: prepared.record.circuitPreparation)
        }
        return try await execute(prepared, cancellation: cancellation)
    }
}

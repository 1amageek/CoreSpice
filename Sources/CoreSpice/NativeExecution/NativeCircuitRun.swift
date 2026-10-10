import CoreSpiceParsedIR
import CoreSpiceAnalysis

/// Numerical results and completed phase facts retain their admitted storage.
public struct NativeCircuitRun<Result: Sendable>: Sendable {
    public let result: Result
    public let statistics: TransientExecutionStatistics?
    public let phases: [NativeCircuitExecutionFacts]
    internal let reservation: NativeExecutionStorage
    internal init(result: Result, phases: [NativeCircuitExecutionFacts], reservation: NativeExecutionStorage, statistics: TransientExecutionStatistics? = nil) where Result: AnalysisResultStorageRetaining {
        self.statistics = statistics; self.result = result.retainingStorage(reservation)
        self.phases = phases; self.reservation = reservation
    }
}

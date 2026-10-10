import CoreSpiceParsedIR
import CoreSpiceAnalysis

/// Numerical results and completed phase facts retain their admitted storage.
public struct NativeCircuitRun<Result: Sendable>: Sendable {
    public let result: Result
    public let statistics: TransientExecutionStatistics?
    public let phases: [NativeCircuitExecutionFacts]
    internal let reservation: SPICESourceStorageReservation
    internal init(result: Result, phases: [NativeCircuitExecutionFacts], reservation: SPICESourceStorageReservation, statistics: TransientExecutionStatistics? = nil) where Result: AnalysisResultStorageRetaining {
        self.statistics = statistics; self.result = result.retainingStorage(reservation)
        self.phases = phases; self.reservation = reservation
    }
}

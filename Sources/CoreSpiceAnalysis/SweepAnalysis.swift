import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent

/// Parametric sweep wrapper that runs an inner analysis at each sweep point.
///
/// `SweepAnalysis` iterates over a sequence of parameter values,
/// constructing a fresh inner analysis for each value via the
/// `analysisFactory` closure, and collecting all results into a
/// ``SweepResult``.
public struct SweepAnalysis<A: Analysis>: Sendable {

    /// The name of the parameter being swept.
    public let parameterName: String

    /// The parameter values to sweep through.
    public let values: [Double]

    /// A factory that creates the inner analysis for a given parameter value.
    public let analysisFactory: @Sendable (Double) -> A

    public init(
        parameterName: String,
        values: [Double],
        analysisFactory: @Sendable @escaping (Double) -> A
    ) {
        self.parameterName = parameterName
        self.values = values
        self.analysisFactory = analysisFactory
    }

    /// Runs the sweep, executing the inner analysis at each parameter value.
    ///
    /// - Parameters:
    ///   - plan: The compiled execution plan.
    ///   - devices: Bound device instances.
    ///   - solver: The linear solver.
    ///   - observer: Optional event dispatcher.
    ///   - cancellation: Cooperative cancellation token.
    /// - Returns: A ``SweepResult`` containing results from all sweep points.
    /// - Throws: ``AnalysisError/cancelled`` if cancelled, or any error from the inner analysis.
    public func run(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: any LinearSolver,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> SweepResult<A.Result> {
        try PreparedCircuit.validate(plan: plan, devices: devices)
        var results: [A.Result] = []

        for (idx, value) in values.enumerated() {
            if cancellation.isCancelled {
                throw AnalysisError.cancelled
            }

            await observer?.emit(.sweepPointStarted(SweepPointInfo(
                id: AnalysisID(),
                index: idx,
                total: values.count,
                value: value,
                parameterName: parameterName
            )))

            let analysis = analysisFactory(value)
            let result = try await analysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: observer,
                cancellation: cancellation
            )
            results.append(result)
        }

        return SweepResult(
            parameterName: parameterName,
            values: values,
            results: results
        )
    }
}

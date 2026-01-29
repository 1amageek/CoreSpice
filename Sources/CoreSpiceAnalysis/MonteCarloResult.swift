/// The result of a Monte Carlo analysis.
///
/// Collects the inner analysis result from each iteration along with
/// the randomized parameter values used in that iteration.
public struct MonteCarloResult<InnerResult: Sendable>: Sendable {
    /// The number of Monte Carlo iterations performed.
    public let iterations: Int

    /// The inner analysis result from each iteration.
    public let results: [InnerResult]

    /// The parameter values used in each iteration.
    /// Each entry is a dictionary mapping "deviceName.paramName" to the sampled value.
    public let parameterValues: [[String: Double]]

    /// The random seed used (if deterministic mode was enabled).
    public let seed: UInt64?

    public init(
        iterations: Int,
        results: [InnerResult],
        parameterValues: [[String: Double]],
        seed: UInt64?
    ) {
        self.iterations = iterations
        self.results = results
        self.parameterValues = parameterValues
        self.seed = seed
    }
}

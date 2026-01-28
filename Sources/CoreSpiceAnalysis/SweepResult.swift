/// The result of a parametric sweep analysis.
///
/// Collects one inner-analysis result per sweep point, along with the
/// parameter name and the values at which the sweep was evaluated.
public struct SweepResult<PointResult: Sendable>: Sendable {

    /// The name of the swept parameter.
    public let parameterName: String

    /// The parameter values at which the inner analysis was run.
    public let values: [Double]

    /// The inner-analysis results, one per sweep point.
    public let results: [PointResult]

    public init(
        parameterName: String,
        values: [Double],
        results: [PointResult]
    ) {
        self.parameterName = parameterName
        self.values = values
        self.results = results
    }
}

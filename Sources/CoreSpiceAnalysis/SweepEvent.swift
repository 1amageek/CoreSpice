/// Events emitted during a parametric sweep analysis.
///
/// These provide a simplified view of sweep progress. The full event
/// stream (including inner-analysis events) flows through
/// ``CoreSpiceEvent/AnalysisEvent``.
public enum SweepEvent: Sendable {

    /// The sweep has started.
    case started(parameterName: String, pointCount: Int)

    /// A sweep point has started.
    case pointStarted(index: Int, value: Double)

    /// A sweep point has finished.
    case pointFinished(index: Int, value: Double)

    /// The sweep has finished.
    case finished
}

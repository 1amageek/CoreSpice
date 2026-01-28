/// Events emitted during AC small-signal analysis.
///
/// These events provide a simplified view of the AC sweep progress.
/// Detailed events (Newton iterations for the DC operating point,
/// individual frequency point progress) flow through the main
/// ``CoreSpiceEvent/AnalysisEvent`` stream.
public enum ACEvent: Sendable {

    /// The AC analysis has started.
    case started(frequencyCount: Int)

    /// A frequency point has been evaluated.
    case frequencyPoint(index: Int, frequency: Double)

    /// The AC analysis has finished.
    case finished
}

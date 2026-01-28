/// Events emitted during transient (time-domain) analysis.
///
/// These provide a simplified view of the transient simulation
/// progress. The full event stream (Newton iterations, LTE info,
/// timestep rejections) flows through ``CoreSpiceEvent/AnalysisEvent``.
public enum TransientEvent: Sendable {

    /// The transient analysis has started.
    case started(stopTime: Double)

    /// A timestep has been accepted.
    case timeStep(time: Double, dt: Double, iterations: Int)

    /// A timestep was rejected and will be retried with a smaller step.
    case stepRejected(time: Double, dt: Double, reason: String)

    /// The transient analysis has finished.
    case finished(totalSteps: Int, rejectedSteps: Int)
}

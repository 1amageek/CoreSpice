/// Events emitted during DC operating point analysis.
///
/// These events provide a simplified view of the DC analysis progress.
/// The full event stream (Newton iterations, convergence details) is
/// delivered through ``CoreSpiceEvent/AnalysisEvent`` via the observer.
public enum DCEvent: Sendable {

    /// The DC analysis has started.
    case started(nodeCount: Int, deviceCount: Int)

    /// A Newton-Raphson iteration has completed.
    case newtonIteration(iteration: Int, residual: Double)

    /// The Newton-Raphson solver has converged.
    case converged(iterations: Int)

    /// The DC analysis has finished.
    case finished
}

import CoreSpiceDevices

/// Supplies original signed equations for direct Newton corrections and physical convergence.
public protocol NonlinearPhysicalResidualEvaluating: Sendable {
    func accumulateResidual(state: SolutionState, add: (Int, Double) -> Void) throws
}

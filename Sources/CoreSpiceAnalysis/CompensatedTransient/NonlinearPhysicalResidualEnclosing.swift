import CoreSpiceDevices

/// Encloses original global equations at a compensated candidate.
public protocol NonlinearPhysicalResidualEnclosing: Sendable {
    func accumulateResidualEnclosure(
        state: SolutionState, add: (Int, CompensatedValue, Double) -> Void
    ) throws
}

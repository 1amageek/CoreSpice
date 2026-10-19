/// Supplies original physical DC equations using the actual admitted device law.
public protocol DCPhysicalResidualContributing: Sendable {
    func accumulatePhysicalResidual(state: SolutionState, add: (Int, Double) -> Void) throws
}

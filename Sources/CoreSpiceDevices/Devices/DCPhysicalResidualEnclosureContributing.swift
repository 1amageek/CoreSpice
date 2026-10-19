/// Supplies enclosed original DC equations using the actual admitted device law.
public protocol DCPhysicalResidualEnclosureContributing: BoundDevice {
    func accumulatePhysicalResidualEnclosure(
        state: SolutionState, sourceScale: Double,
        add: (Int, CompensatedValue, Double) -> Void
    ) throws
}

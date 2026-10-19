/// Exact minimum-degree ordering, sharing the historical AMD implementation.
public struct MinimumDegreeOrdering: Sendable {
    public static func compute(
        structure: SparseStructure,
        control: (any LinearSolverExecutionControlling)? = nil
    ) throws -> Permutation {
        try AMDOrdering.compute(structure: structure, control: control)
    }
}

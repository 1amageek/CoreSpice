/// Identity ordering for an already well-ordered sparse matrix.
public struct NaturalOrdering: Sendable {
    public static func compute(structure: SparseStructure) -> Permutation {
        .identity(size: structure.dimension)
    }
}

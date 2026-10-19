/// Structural ordering failures; caller control failures propagate unchanged.
public enum SparseOrderingError: Error, Sendable, Equatable {
    case capacityOverflow
    case invalidPermutation
}

/// Portable failures at an accounted storage boundary.
public enum SPICESourceStorageError: Error, Sendable, Equatable {
    case arithmeticOverflow
    case invalidCapacity
    case indexOutOfBounds
}

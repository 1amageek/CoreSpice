public enum OpticalStateAccessError: Error, Sendable, Equatable {
    case nodeOutOfBounds(nodeID: Int, nodeCount: Int)
    case groundNodeIsImmutable
}

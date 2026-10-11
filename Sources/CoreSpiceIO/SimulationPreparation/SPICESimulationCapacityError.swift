/// Required capacity at the owning preparation boundary; no partial input is published.
public enum SPICESimulationCapacityError: Error, Sendable, Equatable {
    public enum Boundary: String, Sendable {
        case catalogAndRoutes, parsedTransform, loweredInstances, loweredNodes
    }
    case elements(boundary: Boundary, limit: Int, requested: Int)
    case transformBytes(limit: UInt64, requested: UInt64)
}

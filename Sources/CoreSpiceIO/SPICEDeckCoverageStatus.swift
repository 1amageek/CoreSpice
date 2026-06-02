/// Execution coverage status for one SPICE deck item.
public enum SPICEDeckCoverageStatus: String, Sendable, Hashable, Codable {
    case preserved
    case applied
    case supported
    case warning
    case blocked
}

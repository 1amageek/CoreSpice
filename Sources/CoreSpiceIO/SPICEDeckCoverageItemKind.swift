/// Category for a SPICE deck coverage item.
public enum SPICEDeckCoverageItemKind: String, Sendable, Hashable, Codable {
    case analysis
    case directive
    case option
    case measurement
    case preprocessing
}

/// Category for a SPICE deck coverage item.
public enum SPICEDeckCoverageItemKind: String, Sendable, Hashable, Codable {
    case analysis
    case component
    case directive
    case model
    case option
    case measurement
    case preprocessing
}

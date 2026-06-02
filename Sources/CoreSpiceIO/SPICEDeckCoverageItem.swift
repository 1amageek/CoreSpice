import CoreSpiceParsedIR

/// Coverage information for one parsed SPICE deck item.
public struct SPICEDeckCoverageItem: Sendable, Hashable, Codable {

    public let kind: SPICEDeckCoverageItemKind
    public let name: String
    public let status: SPICEDeckCoverageStatus
    public let message: String
    public let location: SourceLocation?

    public init(
        kind: SPICEDeckCoverageItemKind,
        name: String,
        status: SPICEDeckCoverageStatus,
        message: String,
        location: SourceLocation? = nil
    ) {
        self.kind = kind
        self.name = name
        self.status = status
        self.message = message
        self.location = location
    }
}

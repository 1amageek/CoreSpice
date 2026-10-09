import CoreSpiceParsedIR

/// Availability lookup only; all occurrence coordinates and context come from the grammar.
public struct SPICESourceCatalogRoute: Sendable, Hashable {
    public let parentKey: String
    public let childKey: String
    public let literalRoute: String
    public let kind: SPICESourceDependencyEvent.Kind
    public let selectedSection: String?
    public init(parentKey: String, childKey: String, literalRoute: String,
                kind: SPICESourceDependencyEvent.Kind, selectedSection: String? = nil) {
        self.parentKey = parentKey; self.childKey = childKey; self.literalRoute = literalRoute
        self.kind = kind; self.selectedSection = selectedSection
    }
}

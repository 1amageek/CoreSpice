/// One dependency occurrence emitted by the SPICE grammar in lexical depth-first order.
public struct SPICESourceDependencyEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case include, externalLibrary }
    public let parentCaptureID: String?
    public let childCaptureID: String?
    public let location: SourceLocation?
    public let kind: Kind
    public let path: String
    public let selectedSection: String?
    public let ordinal: Int
    public let preprocessingContext: [String: String]
    public let parentOccurrenceID: SPICEParseOccurrenceID?
    public let childOccurrenceID: SPICEParseOccurrenceID?
    public let statementByteOffset: UInt64?
    public let statementOrdinal: UInt64?
    public let parentSection: String?
    public let preprocessingIdentity: String?

    public init(parentCaptureID: String?, childCaptureID: String?, location: SourceLocation?,
                kind: Kind, path: String, selectedSection: String?, ordinal: Int,
                preprocessingContext: [String: String],
                parentOccurrenceID: SPICEParseOccurrenceID? = nil, childOccurrenceID: SPICEParseOccurrenceID? = nil,
                statementByteOffset: UInt64? = nil, statementOrdinal: UInt64? = nil,
                parentSection: String? = nil, preprocessingIdentity: String? = nil) {
        self.parentCaptureID = parentCaptureID
        self.childCaptureID = childCaptureID
        self.location = location
        self.kind = kind
        self.path = path
        self.selectedSection = selectedSection
        self.ordinal = ordinal
        self.preprocessingContext = preprocessingContext
        self.parentOccurrenceID = parentOccurrenceID; self.childOccurrenceID = childOccurrenceID
        self.statementByteOffset = statementByteOffset; self.statementOrdinal = statementOrdinal
        self.parentSection = parentSection; self.preprocessingIdentity = preprocessingIdentity
    }
}

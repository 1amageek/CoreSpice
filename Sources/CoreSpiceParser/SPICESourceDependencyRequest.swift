import CoreSpiceParsedIR

/// Immutable grammar context for an active child acquisition.
public struct SPICESourceDependencyRequest: Sendable {
    public let parentSourceKey: String
    public let parentOccurrenceID: SPICEParseOccurrenceID
    public let statementByteOffset: UInt64
    public let statementOrdinal: UInt64
    public let kind: SPICESourceDependencyEvent.Kind
    public let literalRoute: String
    public let parentSection: String?
    public let requestedChildSection: String?
    public let environment: SPICEPreprocessingEnvironment

    public init(parentSourceKey: String, parentOccurrenceID: SPICEParseOccurrenceID,
        statementByteOffset: UInt64, statementOrdinal: UInt64, kind: SPICESourceDependencyEvent.Kind,
        literalRoute: String, parentSection: String?, requestedChildSection: String?,
        environment: SPICEPreprocessingEnvironment) {
        self.parentSourceKey = parentSourceKey; self.parentOccurrenceID = parentOccurrenceID
        self.statementByteOffset = statementByteOffset; self.statementOrdinal = statementOrdinal
        self.kind = kind; self.literalRoute = literalRoute; self.parentSection = parentSection
        self.requestedChildSection = requestedChildSection; self.environment = environment
    }
}

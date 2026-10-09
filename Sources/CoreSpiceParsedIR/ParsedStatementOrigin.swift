/// Actual source and statement coordinates retained by the parser.
public struct ParsedStatementOrigin: Sendable, Hashable {
    public let captureID: String
    public let occurrenceID: SPICEParseOccurrenceID?
    public let location: SourceLocation
    public let statementByteOffset: UInt64?
    public let statementOrdinal: UInt64?

    public init(captureID: String, location: SourceLocation,
                occurrenceID: SPICEParseOccurrenceID? = nil,
                statementByteOffset: UInt64? = nil, statementOrdinal: UInt64? = nil) {
        self.captureID = captureID
        self.location = location
        self.occurrenceID = occurrenceID
        self.statementByteOffset = statementByteOffset
        self.statementOrdinal = statementOrdinal
    }
}

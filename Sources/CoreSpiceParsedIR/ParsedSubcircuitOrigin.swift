/// An actual source occurrence and physical subcircuit declaration start.
public struct ParsedSubcircuitOrigin: Sendable, Hashable {
    public let captureID: String
    public let occurrenceID: SPICEParseOccurrenceID?
    public let location: SourceLocation
    public let ordinal: Int
    public let statementByteOffset: UInt64?
    public let statementOrdinal: UInt64?

    public init(captureID: String, location: SourceLocation, ordinal: Int,
                occurrenceID: SPICEParseOccurrenceID? = nil,
                statementByteOffset: UInt64? = nil, statementOrdinal: UInt64? = nil) {
        self.captureID = captureID; self.location = location; self.ordinal = ordinal
        self.occurrenceID = occurrenceID; self.statementByteOffset = statementByteOffset
        self.statementOrdinal = statementOrdinal
    }
}

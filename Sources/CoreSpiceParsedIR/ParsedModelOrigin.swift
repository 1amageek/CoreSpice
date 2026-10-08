/// The actual captured source and physical declaration start selected by parsing.
public struct ParsedModelOrigin: Sendable, Hashable {
    public let captureID: String
    public let location: SourceLocation
    public let ordinal: Int
    public let occurrenceID: SPICEParseOccurrenceID?
    public let statementByteOffset: UInt64?
    public let statementOrdinal: UInt64?

    public var declarationID: String {
        let legacy = "\(captureID):model:\(location.line):\(location.column):\(ordinal)"
        if let occurrenceID { return "\(legacy):occurrence:\(occurrenceID.rawValue)" }
        return legacy
    }

    public init(captureID: String, location: SourceLocation, ordinal: Int,
                occurrenceID: SPICEParseOccurrenceID? = nil,
                statementByteOffset: UInt64? = nil, statementOrdinal: UInt64? = nil) {
        self.captureID = captureID
        self.location = location
        self.ordinal = ordinal
        self.occurrenceID = occurrenceID
        self.statementByteOffset = statementByteOffset
        self.statementOrdinal = statementOrdinal
    }
}

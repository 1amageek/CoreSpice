/// Opaque source provenance supplied by the parser; no content digest is invented.
public struct MOSSourceOccurrence: Sendable, Hashable {
    public let captureID: String?
    public let occurrenceID: UInt64?
    public let path: String?
    public let line: Int?
    public let column: Int?
    public let statementByteOffset: UInt64?
    public let statementOrdinal: UInt64?
    public init(captureID: String?, occurrenceID: UInt64?, path: String?, line: Int?, column: Int?,
                statementByteOffset: UInt64?, statementOrdinal: UInt64?) {
        self.captureID = captureID; self.occurrenceID = occurrenceID; self.path = path
        self.line = line; self.column = column; self.statementByteOffset = statementByteOffset
        self.statementOrdinal = statementOrdinal
    }
}

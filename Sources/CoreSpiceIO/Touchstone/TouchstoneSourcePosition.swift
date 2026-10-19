/// A physical position in the supplied ASCII bytes; lines and columns are one-based.
public struct TouchstoneSourcePosition: Sendable, Equatable {
    public let sourceName: String?
    public let byteOffset: UInt64
    public let line: Int
    public let column: Int

    public init(sourceName: String? = nil, byteOffset: UInt64 = 0, line: Int = 1, column: Int = 1) {
        self.sourceName = sourceName
        self.byteOffset = byteOffset
        self.line = line
        self.column = column
    }
}

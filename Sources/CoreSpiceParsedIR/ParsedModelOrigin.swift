/// The actual captured source and physical declaration start selected by parsing.
public struct ParsedModelOrigin: Sendable, Hashable {
    public let captureID: String
    public let location: SourceLocation
    public let ordinal: Int

    public var declarationID: String {
        "\(captureID):model:\(location.line):\(location.column):\(ordinal)"
    }

    public init(captureID: String, location: SourceLocation, ordinal: Int) {
        self.captureID = captureID
        self.location = location
        self.ordinal = ordinal
    }
}

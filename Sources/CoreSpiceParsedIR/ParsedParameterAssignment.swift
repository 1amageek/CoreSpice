/// A named assignment in source order, before executable dictionary collapse.
public struct ParsedParameterAssignment: Sendable, Hashable {
    public let name: String
    public let value: ParsedParameterValue
    public let location: SourceLocation?
    public let origin: ParsedStatementOrigin?
    /// Remaining supplied coordinates of a multi-value assignment such as MOS IC.
    public let additionalValues: [ParsedParameterValue]

    public init(name: String, value: ParsedParameterValue, location: SourceLocation? = nil,
                origin: ParsedStatementOrigin? = nil, additionalValues: [ParsedParameterValue] = []) {
        self.name = name
        self.value = value
        self.location = location
        self.origin = origin
        self.additionalValues = additionalValues
    }
}

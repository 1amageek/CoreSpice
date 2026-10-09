/// A function declaration with its actual source occurrence, owned by its lexical body.
public struct ParsedFunctionDefinition: Sendable, Hashable {
    public let name: String
    public let parameters: [String]
    public let body: ParsedExpression
    public let location: SourceLocation?
    public let origin: ParsedStatementOrigin?

    public init(name: String, parameters: [String], body: ParsedExpression,
                location: SourceLocation? = nil, origin: ParsedStatementOrigin? = nil) {
        self.name = name
        self.parameters = parameters
        self.body = body
        self.location = location
        self.origin = origin
    }
}

import CoreSpiceParsedIR

/// A SPICE `.func` definition registered during lowering.
public struct UserFunctionDefinition: Sendable, Hashable {

    /// The function name.
    public let name: String

    /// The positional argument names.
    public let parameters: [String]

    /// The function body expression.
    public let body: ParsedExpression

    public init(name: String, parameters: [String], body: ParsedExpression) {
        self.name = name
        self.parameters = parameters
        self.body = body
    }
}

/// A parameter value as parsed from source, before evaluation.
///
/// Parameter values can be simple literals or expressions that
/// reference other parameters. They are resolved during lowering.
public enum ParsedParameterValue: Sendable, Hashable {

    /// A numeric value, possibly with a scale suffix (e.g., "1k", "10u").
    case numeric(Double)

    /// A string value.
    case string(String)

    /// An expression to be evaluated.
    case expression(ParsedExpression)

    /// A boolean flag value.
    case boolean(Bool)
}

extension ParsedParameterValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .numeric(let value):
            return "\(value)"
        case .string(let value):
            return "\"\(value)\""
        case .expression(let expr):
            return "{\(expr)}"
        case .boolean(let value):
            return value ? "true" : "false"
        }
    }
}

extension ParsedParameterValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .numeric(value)
    }
}

extension ParsedParameterValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .numeric(Double(value))
    }
}

extension ParsedParameterValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension ParsedParameterValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .boolean(value)
    }
}

/// A parsed expression representing a parameter value or formula.
///
/// Expressions are evaluated during lowering to produce concrete values.
/// They support arithmetic operations, function calls, and conditionals.
public indirect enum ParsedExpression: Sendable, Hashable {

    /// A literal numeric value.
    case literal(Double)

    /// A reference to a named parameter or variable.
    case identifier(String)

    /// A unary operation applied to an expression.
    case unaryOperation(UnaryOperator, ParsedExpression)

    /// A binary operation between two expressions.
    case binaryOperation(BinaryOperator, ParsedExpression, ParsedExpression)

    /// A function call with arguments.
    case functionCall(name: String, arguments: [ParsedExpression])

    /// A conditional expression (ternary operator).
    case conditional(condition: ParsedExpression, then: ParsedExpression, else: ParsedExpression)
}

/// Unary operators for expressions.
public enum UnaryOperator: String, Sendable, Hashable, Codable {
    case negate = "-"
    case not = "!"
    case plus = "+"
}

/// Binary operators for expressions.
public enum BinaryOperator: String, Sendable, Hashable, Codable {
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
    case power = "**"
    case modulo = "%"

    // Comparison
    case equal = "=="
    case notEqual = "!="
    case lessThan = "<"
    case lessOrEqual = "<="
    case greaterThan = ">"
    case greaterOrEqual = ">="

    // Logical
    case and = "&&"
    case or = "||"
}

extension ParsedExpression: CustomStringConvertible {
    public var description: String {
        switch self {
        case .literal(let value):
            return "\(value)"
        case .identifier(let name):
            return name
        case .unaryOperation(let operation, let expression):
            return "(\(operation.rawValue)\(expression))"
        case .binaryOperation(let operation, let lhs, let rhs):
            return "(\(lhs) \(operation.rawValue) \(rhs))"
        case .functionCall(let name, let args):
            return "\(name)(\(args.map { $0.description }.joined(separator: ", ")))"
        case .conditional(let cond, let then, let `else`):
            return "(\(cond) ? \(then) : \(`else`))"
        }
    }
}

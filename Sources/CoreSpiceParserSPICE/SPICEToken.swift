import CoreSpiceParsedIR

/// A token in the SPICE lexer output.
public enum SPICEToken: Sendable, Hashable {

    // Literals
    case number(Double)
    case identifier(String)
    case string(String)
    case invalidNumericLiteral(String)
    case invalidNumericSuffix(String)

    // Punctuation
    case equals
    case comma
    case leftParen
    case rightParen
    case leftBrace
    case rightBrace
    case plus
    case minus
    case asterisk
    case slash
    case caret
    case percent
    case lessThan
    case greaterThan
    case exclamation
    case ampersand
    case pipe
    case question
    case colon
    case semicolon
    case dotOperator(String)

    // Special
    case newline
    case continuation
    case comment(String)
    case endOfFile

    // Directives (starting with .)
    case directive(String)

    /// The location of this token in the source.
    public struct Located: Sendable, Hashable {
        public let token: SPICEToken
        public let location: SourceLocation

        public init(token: SPICEToken, location: SourceLocation) {
            self.token = token
            self.location = location
        }
    }
}

extension SPICEToken: CustomStringConvertible {
    public var description: String {
        switch self {
        case .number(let value):
            return "number(\(value))"
        case .identifier(let name):
            return "identifier(\(name))"
        case .string(let value):
            return "string(\"\(value)\")"
        case .invalidNumericLiteral(let text):
            return "invalidNumericLiteral(\(text))"
        case .invalidNumericSuffix(let suffix):
            return "invalidNumericSuffix(\(suffix))"
        case .equals:
            return "="
        case .comma:
            return ","
        case .leftParen:
            return "("
        case .rightParen:
            return ")"
        case .leftBrace:
            return "{"
        case .rightBrace:
            return "}"
        case .plus:
            return "+"
        case .minus:
            return "-"
        case .asterisk:
            return "*"
        case .slash:
            return "/"
        case .caret:
            return "^"
        case .percent:
            return "%"
        case .lessThan:
            return "<"
        case .greaterThan:
            return ">"
        case .exclamation:
            return "!"
        case .ampersand:
            return "&"
        case .pipe:
            return "|"
        case .question:
            return "?"
        case .colon:
            return ":"
        case .semicolon:
            return ";"
        case .dotOperator(let name):
            return ".\(name)."
        case .newline:
            return "newline"
        case .continuation:
            return "+"
        case .comment(let text):
            return "comment(\(text))"
        case .endOfFile:
            return "EOF"
        case .directive(let name):
            return ".\(name)"
        }
    }
}

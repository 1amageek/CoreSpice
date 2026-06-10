import CoreSpiceParsedIR
import CoreSpiceParser

/// Parses SPICE numeric expressions into the canonical parsed expression IR.
public struct SPICEExpressionParser: Sendable {

    public init() {}

    public func parse(
        _ source: String,
        fileName: String? = nil
    ) throws -> ParsedExpression {
        var lexer = SPICELexer(source: source, fileName: fileName)
        let tokens = lexer.tokenize()
        var parser = SPICEExpressionTokenParser(
            tokens: tokens,
            currentIndex: 0,
            allowedEndTokens: [.endOfFile, .newline]
        )
        let expression = try parser.parseExpression()
        try parser.requireEnd()
        return expression
    }
}

struct SPICEExpressionTokenParser {

    private let tokens: [SPICEToken.Located]
    private let allowedEndTokens: Set<SPICEToken>
    private var current: Int

    var currentIndex: Int {
        current
    }

    init(
        tokens: [SPICEToken.Located],
        currentIndex: Int,
        allowedEndTokens: Set<SPICEToken> = [.endOfFile, .newline, .rightBrace, .comma, .rightParen]
    ) {
        self.tokens = tokens
        self.allowedEndTokens = allowedEndTokens
        self.current = currentIndex
    }

    mutating func parseExpression() throws -> ParsedExpression {
        try parseConditionalExpression()
    }

    mutating func requireEnd() throws {
        guard isAtExpressionEnd else {
            throw ParserDiagnostic.error("Unexpected token in expression: \(currentToken)", at: currentLocation)
        }
    }

    private mutating func parseConditionalExpression() throws -> ParsedExpression {
        let condition = try parseLogicalOrExpression()
        guard consume(.question) else {
            return condition
        }

        let thenExpression = try parseExpression()
        guard consume(.colon) else {
            throw ParserDiagnostic.error("Expected ':' in conditional expression", at: currentLocation)
        }
        let elseExpression = try parseExpression()
        return .conditional(condition: condition, then: thenExpression, else: elseExpression)
    }

    private mutating func parseLogicalOrExpression() throws -> ParsedExpression {
        var left = try parseLogicalAndExpression()

        while consumePair(.pipe, .pipe) || consumeWordOperator("or") || consumeDotOperator("or") {
            let right = try parseLogicalAndExpression()
            left = .binaryOperation(.or, left, right)
        }

        return left
    }

    private mutating func parseLogicalAndExpression() throws -> ParsedExpression {
        var left = try parseEqualityExpression()

        while consumePair(.ampersand, .ampersand) || consumeWordOperator("and") || consumeDotOperator("and") {
            let right = try parseEqualityExpression()
            left = .binaryOperation(.and, left, right)
        }

        return left
    }

    private mutating func parseEqualityExpression() throws -> ParsedExpression {
        var left = try parseComparisonExpression()

        while true {
            if consumePair(.equals, .equals) || consume(.equals) || consumeDotOperator("eq") {
                let right = try parseComparisonExpression()
                left = .binaryOperation(.equal, left, right)
            } else if consumePair(.exclamation, .equals) || consumeDotOperator("ne") {
                let right = try parseComparisonExpression()
                left = .binaryOperation(.notEqual, left, right)
            } else {
                return left
            }
        }
    }

    private mutating func parseComparisonExpression() throws -> ParsedExpression {
        var left = try parseAdditiveExpression()

        while true {
            if consumePair(.lessThan, .equals) || consumeDotOperator("le") {
                let right = try parseAdditiveExpression()
                left = .binaryOperation(.lessOrEqual, left, right)
            } else if consumePair(.greaterThan, .equals) || consumeDotOperator("ge") {
                let right = try parseAdditiveExpression()
                left = .binaryOperation(.greaterOrEqual, left, right)
            } else if consume(.lessThan) || consumeDotOperator("lt") {
                let right = try parseAdditiveExpression()
                left = .binaryOperation(.lessThan, left, right)
            } else if consume(.greaterThan) || consumeDotOperator("gt") {
                let right = try parseAdditiveExpression()
                left = .binaryOperation(.greaterThan, left, right)
            } else {
                return left
            }
        }
    }

    private mutating func parseAdditiveExpression() throws -> ParsedExpression {
        var left = try parseMultiplicativeExpression()

        while true {
            if consume(.plus) {
                let right = try parseMultiplicativeExpression()
                left = .binaryOperation(.add, left, right)
            } else if consume(.minus) {
                let right = try parseMultiplicativeExpression()
                left = .binaryOperation(.subtract, left, right)
            } else {
                return left
            }
        }
    }

    private mutating func parseMultiplicativeExpression() throws -> ParsedExpression {
        var left = try parsePowerExpression()

        while true {
            if consume(.asterisk) {
                let right = try parsePowerExpression()
                left = .binaryOperation(.multiply, left, right)
            } else if consume(.slash) {
                let right = try parsePowerExpression()
                left = .binaryOperation(.divide, left, right)
            } else if consume(.percent) {
                let right = try parsePowerExpression()
                left = .binaryOperation(.modulo, left, right)
            } else {
                return left
            }
        }
    }

    private mutating func parsePowerExpression() throws -> ParsedExpression {
        let base = try parseUnaryExpression()

        if consume(.caret) {
            let exponent = try parsePowerExpression()
            return .binaryOperation(.power, base, exponent)
        }

        return base
    }

    private mutating func parseUnaryExpression() throws -> ParsedExpression {
        if consume(.minus) {
            return .unaryOperation(.negate, try parseUnaryExpression())
        }
        if consume(.plus) {
            return .unaryOperation(.plus, try parseUnaryExpression())
        }
        if consume(.exclamation) || consumeWordOperator("not") || consumeDotOperator("not") {
            return .unaryOperation(.not, try parseUnaryExpression())
        }
        return try parsePrimaryExpression()
    }

    private mutating func parsePrimaryExpression() throws -> ParsedExpression {
        switch currentToken {
        case .number(let value):
            advance()
            return .literal(value)
        case .invalidNumericLiteral(let text):
            throw ParserDiagnostic.error("Invalid numeric literal '\(text)'", at: currentLocation)
        case .invalidNumericSuffix(let suffix):
            throw ParserDiagnostic.error("Unknown numeric suffix '\(suffix)'", at: currentLocation)
        case .identifier(let name):
            advance()
            if consume(.leftParen) {
                var arguments: [ParsedExpression] = []
                if !consume(.rightParen) {
                    while true {
                        arguments.append(try parseExpression())
                        if consume(.rightParen) {
                            break
                        }
                        guard consume(.comma) else {
                            throw ParserDiagnostic.error("Expected ',' or ')' in function call", at: currentLocation)
                        }
                    }
                }
                return .functionCall(name: name, arguments: arguments)
            }
            return .identifier(name)
        case .leftParen:
            advance()
            let expression = try parseExpression()
            guard consume(.rightParen) else {
                throw ParserDiagnostic.error("Expected ')' in expression", at: currentLocation)
            }
            return expression
        default:
            throw ParserDiagnostic.error("Unexpected token in expression: \(currentToken)", at: currentLocation)
        }
    }

    private mutating func consume(_ token: SPICEToken) -> Bool {
        guard currentToken == token else {
            return false
        }
        advance()
        return true
    }

    private mutating func consumePair(_ first: SPICEToken, _ second: SPICEToken) -> Bool {
        guard currentToken == first,
              current + 1 < tokens.count,
              tokens[current + 1].token == second else {
            return false
        }
        advance()
        advance()
        return true
    }

    private mutating func consumeWordOperator(_ name: String) -> Bool {
        guard case .identifier(let identifier) = currentToken,
              identifier.lowercased() == name else {
            return false
        }
        advance()
        return true
    }

    private mutating func consumeDotOperator(_ name: String) -> Bool {
        guard case .dotOperator(let operatorName) = currentToken,
              operatorName == name else {
            return false
        }
        advance()
        return true
    }

    private mutating func advance() {
        if current < tokens.count {
            current += 1
        }
    }

    private var currentToken: SPICEToken {
        guard current < tokens.count else {
            return .endOfFile
        }
        return tokens[current].token
    }

    private var currentLocation: SourceLocation {
        guard current < tokens.count else {
            return SourceLocation.unknown(line: 0, column: 0)
        }
        return tokens[current].location
    }

    private var isAtExpressionEnd: Bool {
        allowedEndTokens.contains(currentToken)
    }
}

import CoreSpiceParsedIR
import CoreSpiceParser

/// Parses SPICE numeric expressions into the canonical parsed expression IR.
public struct SPICEExpressionParser: Sendable {

    public init() {}

    public func parse(
        _ source: String,
        fileName: String? = nil,
        work: (any SPICESourceWorkAccounting)? = nil
    ) throws -> ParsedExpression {
        var lexer = SPICELexer(expressionSource: source, fileName: fileName)
        let tokens = try lexer.tokenizeChecked(work: work)
        for token in tokens where token.token == .unterminatedQuote {
            throw ParserDiagnostic.error("Unterminated quoted value", at: token.location)
        }
        // Each token bounds at most one retained expression node.
        try work?.charge(.retainedElements, units: UInt64(tokens.count))
        var parser = SPICEExpressionTokenParser(
            tokens: tokens,
            currentIndex: 0,
            allowedEndTokens: [.endOfFile, .newline],
            work: work
        )
        let expression = try parser.parseExpression()
        try parser.requireEnd()
        return expression
    }
    /// Bounded callers retain the local lexer/AST owner through their parent scope.
    func parse(_ source: String, fileName: String? = nil,
               storage: inout SPICEParseStorage) throws -> ParsedExpression {
        var lexer = SPICELexer(expressionSource: source, fileName: fileName)
        let owned = try lexer.tokenizeOwned(resources: storage.resources)
        var scope = SPICEParseStorage(resources: storage.resources)
        try scope.hold(owned.storage)
        for token in owned.tokens {
            try storage.resources.checkCancellation()
            if token.token == .unterminatedQuote {
                throw ParserDiagnostic.error("Unterminated quoted value", at: token.location)
            }
        }
        var parser = SPICEExpressionTokenParser(tokens: owned.tokens, currentIndex: 0,
            allowedEndTokens: [.endOfFile, .newline], work: storage.resources)
        let expression = try parser.parseExpression(storage: &scope)
        try parser.requireEnd()
        try storage.resources.checkCancellation()
        try storage.hold(scope)
        return expression
    }

}

struct SPICEExpressionTokenParser {

    private var storage: SPICEParseStorage?
    private var bounded = false
    private var work: (any SPICESourceWorkAccounting)?
    private let tokens: [SPICEToken.Located]
    private let allowedEndTokens: Set<SPICEToken>
    private var current: Int

    var currentIndex: Int {
        current
    }

    init(
        tokens: [SPICEToken.Located],
        currentIndex: Int,
        allowedEndTokens: Set<SPICEToken> = [.endOfFile, .newline, .rightBrace, .comma, .rightParen],
        work: (any SPICESourceWorkAccounting)? = nil
    ) {
        self.work = work
        self.tokens = tokens
        self.allowedEndTokens = allowedEndTokens
        self.current = currentIndex
    }

    mutating func parseExpression() throws -> ParsedExpression {
        try work?.checkCancellation()
        try work?.charge(.retainedElements, units: 1)
        return try parseConditionalExpression()
    }

    mutating func parseExpression(storage parent: inout SPICEParseStorage) throws -> ParsedExpression {
        bounded = true
        work = parent.resources
        storage = SPICEParseStorage(resources: parent.resources)
        defer { storage = nil }
        let expression = try parseExpression()
        guard let storage else { preconditionFailure("Missing expression storage") }
        try parent.resources.checkCancellation()
        try parent.hold(storage)
        return expression
    }

    mutating func requireEnd() throws {
        try work?.checkCancellation()
        guard isAtExpressionEnd else {
            if bounded { throw ParserDiagnostic.error("Unexpected token in expression", at: currentLocation) }
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
        return try makeConditional(condition, thenExpression, elseExpression)
    }

    private mutating func parseLogicalOrExpression() throws -> ParsedExpression {
        var left = try parseLogicalAndExpression()

        while try consumePair(.pipe, .pipe) || consumeWordOperator("or") || consumeDotOperator("or") {
            let right = try parseLogicalAndExpression()
            left = try makeBinary(.or, left, right)
        }

        return left
    }

    private mutating func parseLogicalAndExpression() throws -> ParsedExpression {
        var left = try parseEqualityExpression()

        while try consumePair(.ampersand, .ampersand) || consumeWordOperator("and") || consumeDotOperator("and") {
            let right = try parseEqualityExpression()
            left = try makeBinary(.and, left, right)
        }

        return left
    }

    private mutating func parseEqualityExpression() throws -> ParsedExpression {
        var left = try parseComparisonExpression()

        while true {
            if consumePair(.equals, .equals) || consume(.equals) || consumeDotOperator("eq") {
                let right = try parseComparisonExpression()
                left = try makeBinary(.equal, left, right)
            } else if consumePair(.exclamation, .equals) || consumeDotOperator("ne") {
                let right = try parseComparisonExpression()
                left = try makeBinary(.notEqual, left, right)
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
                left = try makeBinary(.lessOrEqual, left, right)
            } else if consumePair(.greaterThan, .equals) || consumeDotOperator("ge") {
                let right = try parseAdditiveExpression()
                left = try makeBinary(.greaterOrEqual, left, right)
            } else if consume(.lessThan) || consumeDotOperator("lt") {
                let right = try parseAdditiveExpression()
                left = try makeBinary(.lessThan, left, right)
            } else if consume(.greaterThan) || consumeDotOperator("gt") {
                let right = try parseAdditiveExpression()
                left = try makeBinary(.greaterThan, left, right)
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
                left = try makeBinary(.add, left, right)
            } else if consume(.minus) {
                let right = try parseMultiplicativeExpression()
                left = try makeBinary(.subtract, left, right)
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
                left = try makeBinary(.multiply, left, right)
            } else if consume(.slash) {
                let right = try parsePowerExpression()
                left = try makeBinary(.divide, left, right)
            } else if consume(.percent) {
                let right = try parsePowerExpression()
                left = try makeBinary(.modulo, left, right)
            } else {
                return left
            }
        }
    }

    private mutating func parsePowerExpression() throws -> ParsedExpression {
        let base = try parseUnaryExpression()

        if consume(.caret) {
            let exponent = try parsePowerExpression()
            return try makeBinary(.power, base, exponent)
        }

        return base
    }

    private mutating func parseUnaryExpression() throws -> ParsedExpression {
        if consume(.minus) {
            let operand = try parseUnaryExpression()
            return try makeUnary(.negate, operand)
        }
        if consume(.plus) {
            let operand = try parseUnaryExpression()
            return try makeUnary(.plus, operand)
        }
        if try consume(.exclamation) || consumeWordOperator("not") || consumeDotOperator("not") {
            let operand = try parseUnaryExpression()
            return try makeUnary(.not, operand)
        }
        return try parsePrimaryExpression()
    }

    private mutating func parsePrimaryExpression() throws -> ParsedExpression {
        switch currentToken {
        case .quotedExpression(let source):
            let opening = currentLocation
            advance()
            var lexer = SPICELexer(expressionSource: source, fileName: opening.file)
            if var scope = storage {
                storage = nil
                defer { storage = scope }
                let owned = try lexer.tokenizeOwned(resources: scope.resources)
                try scope.hold(owned.storage)
                let receipt = try SPICESourceCapacity.reserve(of: SPICEToken.Located.self,
                    capacity: owned.tokens.count, kind: .liveOwnedBytes, resources: scope.resources)
                try scope.resources.charge(.projectedBytes, units: receipt.byteCount)
                var interiorTokens: [SPICEToken.Located] = []
                interiorTokens.reserveCapacity(owned.tokens.count)
                for token in owned.tokens {
                    try scope.resources.checkCancellation()
                    try scope.resources.charge(.retainedElements, units: 1)
                    interiorTokens.append(SPICEToken.Located(token: token.token, location: SourceLocation(
                        file: opening.file, line: opening.line + token.location.line - 1,
                        column: token.location.line == 1 ? opening.column + token.location.column : token.location.column)))
                }
                try scope.retain(interiorTokens, reservation: receipt)
                var parser = SPICEExpressionTokenParser(tokens: interiorTokens, currentIndex: 0,
                    allowedEndTokens: [.endOfFile], work: scope.resources)
                let expression = try parser.parseExpression(storage: &scope)
                try parser.requireEnd()
                return expression
            }
            let scanned = try lexer.tokenizeChecked(work: work)
            try work?.charge(.retainedElements, units: UInt64(scanned.count))
            let interiorTokens = scanned.map { token in
                SPICEToken.Located(token: token.token, location: SourceLocation(
                    file: opening.file,
                    line: opening.line + token.location.line - 1,
                    column: token.location.line == 1
                        ? opening.column + token.location.column
                        : token.location.column
                ))
            }
            var parser = SPICEExpressionTokenParser(
                tokens: interiorTokens, currentIndex: 0, allowedEndTokens: [.endOfFile], work: work
            )
            let expression = try parser.parseExpression()
            try parser.requireEnd()
            return expression
        case .string:
            throw ParserDiagnostic.error("Opaque string is not a numeric expression", at: currentLocation)
        case .unterminatedQuote:
            throw ParserDiagnostic.error("Unterminated quoted value", at: currentLocation)
        case .invalidCharacter(let character):
            if bounded { throw ParserDiagnostic.error("Invalid character in expression", at: currentLocation) }
            throw ParserDiagnostic.error("Invalid character '\(character)' in expression", at: currentLocation)
        case .number(let value):
            advance()
            return try makeLiteral(value)
        case .invalidNumericLiteral(let text):
            if bounded { throw ParserDiagnostic.error("Invalid numeric literal", at: currentLocation) }
            throw ParserDiagnostic.error("Invalid numeric literal '\(text)'", at: currentLocation)
        case .invalidNumericSuffix(let suffix):
            if bounded { throw ParserDiagnostic.error("Unknown numeric suffix", at: currentLocation) }
            throw ParserDiagnostic.error("Unknown numeric suffix '\(suffix)'", at: currentLocation)
        case .identifier(let name):
            advance()
            if consume(.leftParen) {
                if var scope = storage {
                    storage = nil
                    var arguments = SPICEAccountedCollection<ParsedExpression>(storageKind: .temporaryBytes)
                    if !consume(.rightParen) {
                        while true {
                            let resources = scope.resources
                            storage = scope
                            scope = SPICEParseStorage(resources: resources)
                            let argument = try parseExpression()
                            guard let updated = storage else { preconditionFailure("Missing argument storage") }
                            scope = updated
                            storage = nil
                            try arguments.append(argument, resources: scope.resources)
                            if consume(.rightParen) { break }
                            guard consume(.comma) else {
                                throw ParserDiagnostic.error("Expected ',' or ')' in function call", at: currentLocation)
                            }
                        }
                    }
                    let ownedArguments = try scope.ownArray(arguments)
                    arguments.removeAll()
                    storage = scope
                    return try makeFunction(name, ownedArguments)
                }
                var arguments: [ParsedExpression] = []
                if !consume(.rightParen) {
                    while true {
                        arguments.append(try parseExpression())
                        if consume(.rightParen) { break }
                        guard consume(.comma) else {
                            throw ParserDiagnostic.error("Expected ',' or ')' in function call", at: currentLocation)
                        }
                    }
                }
                return .functionCall(name: name, arguments: arguments)
            }
            return try makeIdentifier(name)
        case .leftParen:
            advance()
            let expression = try parseExpression()
            guard consume(.rightParen) else {
                throw ParserDiagnostic.error("Expected ')' in expression", at: currentLocation)
            }
            return expression
        default:
            if bounded { throw ParserDiagnostic.error("Unexpected token in expression", at: currentLocation) }
            throw ParserDiagnostic.error("Unexpected token in expression: \(currentToken)", at: currentLocation)
        }
    }

    private mutating func makeLiteral(_ value: Double) throws -> ParsedExpression {
        guard var scope = storage else { return .literal(value) }
        storage = nil
        defer { storage = scope }
        let receipt = try scope.reservePayload(of: Double.self)
        let expression = ParsedExpression.literal(value)
        try scope.retain(expression, reservation: receipt)
        return expression
    }

    private mutating func makeIdentifier(_ name: String) throws -> ParsedExpression {
        guard var scope = storage else { return .identifier(name) }
        storage = nil
        defer { storage = scope }
        let receipt = try scope.reservePayload(of: String.self)
        let expression = ParsedExpression.identifier(name)
        try scope.retain(expression, reservation: receipt)
        return expression
    }

    private mutating func makeUnary(_ operation: UnaryOperator, _ operand: ParsedExpression) throws -> ParsedExpression {
        guard var scope = storage else { return .unaryOperation(operation, operand) }
        storage = nil
        defer { storage = scope }
        let receipt = try scope.reservePayload(of: (UnaryOperator, ParsedExpression).self)
        let expression = ParsedExpression.unaryOperation(operation, operand)
        try scope.retain(expression, reservation: receipt)
        return expression
    }

    private mutating func makeBinary(_ operation: BinaryOperator, _ left: ParsedExpression,
                                     _ right: ParsedExpression) throws -> ParsedExpression {
        guard var scope = storage else { return .binaryOperation(operation, left, right) }
        storage = nil
        defer { storage = scope }
        let receipt = try scope.reservePayload(of: (BinaryOperator, ParsedExpression, ParsedExpression).self)
        let expression = ParsedExpression.binaryOperation(operation, left, right)
        try scope.retain(expression, reservation: receipt)
        return expression
    }

    private mutating func makeConditional(_ condition: ParsedExpression, _ then: ParsedExpression,
                                          _ otherwise: ParsedExpression) throws -> ParsedExpression {
        guard var scope = storage else { return .conditional(condition: condition, then: then, else: otherwise) }
        storage = nil
        defer { storage = scope }
        let receipt = try scope.reservePayload(of: (ParsedExpression, ParsedExpression, ParsedExpression).self)
        let expression = ParsedExpression.conditional(condition: condition, then: then, else: otherwise)
        try scope.retain(expression, reservation: receipt)
        return expression
    }

    private mutating func makeFunction(_ name: String, _ arguments: [ParsedExpression]) throws -> ParsedExpression {
        guard var scope = storage else { return .functionCall(name: name, arguments: arguments) }
        storage = nil
        defer { storage = scope }
        let receipt = try scope.reservePayload(of: (String, [ParsedExpression]).self)
        let expression = ParsedExpression.functionCall(name: name, arguments: arguments)
        try scope.retain(expression, reservation: receipt)
        return expression
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

    private mutating func consumeWordOperator(_ name: String) throws -> Bool {
        guard case .identifier(let identifier) = currentToken else { return false }
        if bounded {
            try work?.checkCancellation()
            try work?.charge(.lexicalBytes, units: UInt64(identifier.utf8.count))
            var expected = name.utf8.makeIterator()
            for byte in identifier.utf8 {
                try work?.checkCancellation()
                guard byte < 128 else {
                    throw SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode expression operators")
                }
                guard expected.next() == (byte >= 65 && byte <= 90 ? byte + 32 : byte) else { return false }
            }
            guard expected.next() == nil else { return false }
        } else if identifier.lowercased() != name { return false }
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

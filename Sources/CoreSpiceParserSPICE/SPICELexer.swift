import CoreSpiceParsedIR
import CoreSpiceParser

/// A lexer for SPICE netlist files.
///
/// The lexer converts raw source text into a stream of tokens
/// that the parser can consume.
public struct SPICELexer: Sendable {

    private let source: String
    private let fileName: String?
    private let configuration: ParserConfiguration
    private var index: String.Index
    private var line: Int = 1
    private var column: Int = 1

    public init(
        source: String,
        fileName: String? = nil,
        configuration: ParserConfiguration = .default
    ) {
        self.source = source
        self.fileName = fileName
        self.configuration = configuration
        self.index = source.startIndex
    }

    /// Tokenizes the entire source.
    public mutating func tokenize() -> [SPICEToken.Located] {
        var tokens: [SPICEToken.Located] = []

        while !isAtEnd {
            if let token = nextToken() {
                tokens.append(token)
            }
        }

        tokens.append(SPICEToken.Located(
            token: .endOfFile,
            location: currentLocation
        ))

        return tokens
    }

    /// Gets the next token.
    public mutating func nextToken() -> SPICEToken.Located? {
        skipWhitespaceAndComments()

        guard !isAtEnd else {
            return nil
        }

        let startLocation = currentLocation
        let char = current

        // Handle newlines
        if char == "\n" {
            advance()
            return SPICEToken.Located(token: .newline, location: startLocation)
        }

        // Handle continuation at start of line (after newline)
        if char == "+" && column == 1 {
            advance()
            return SPICEToken.Located(token: .continuation, location: startLocation)
        }

        // Handle numbers. A leading +/- is emitted as a separate token here; the
        // parser reassembles the sign in value contexts (see parseSignedNumber),
        // which keeps '-' available as the subtraction operator in expressions.
        if char.isNumber || (char == "." && peek()?.isNumber == true) {
            return scanNumber(startLocation: startLocation)
        }

        if char == ".", let token = scanDotOperator(startLocation: startLocation) {
            return token
        }

        // Handle directives
        if char == "." {
            return scanDirective(startLocation: startLocation)
        }

        // Handle identifiers
        if char.isLetter || char == "_" {
            return scanIdentifier(startLocation: startLocation)
        }

        // Handle strings
        if char == "'" || char == "\"" {
            return scanString(startLocation: startLocation)
        }

        // Handle single-character tokens
        switch char {
        case "=":
            advance()
            return SPICEToken.Located(token: .equals, location: startLocation)
        case ",":
            advance()
            return SPICEToken.Located(token: .comma, location: startLocation)
        case "(":
            advance()
            return SPICEToken.Located(token: .leftParen, location: startLocation)
        case ")":
            advance()
            return SPICEToken.Located(token: .rightParen, location: startLocation)
        case "{":
            advance()
            return SPICEToken.Located(token: .leftBrace, location: startLocation)
        case "}":
            advance()
            return SPICEToken.Located(token: .rightBrace, location: startLocation)
        case "+":
            advance()
            return SPICEToken.Located(token: .plus, location: startLocation)
        case "-":
            advance()
            return SPICEToken.Located(token: .minus, location: startLocation)
        case "*":
            // Check for comment
            if column == 1 {
                return scanLineComment(startLocation: startLocation)
            }
            advance()
            // Check for ** (power)
            if current == "*" {
                advance()
                return SPICEToken.Located(token: .caret, location: startLocation)
            }
            return SPICEToken.Located(token: .asterisk, location: startLocation)
        case "/":
            advance()
            return SPICEToken.Located(token: .slash, location: startLocation)
        case "^":
            advance()
            return SPICEToken.Located(token: .caret, location: startLocation)
        case "%":
            advance()
            return SPICEToken.Located(token: .percent, location: startLocation)
        case "<":
            advance()
            return SPICEToken.Located(token: .lessThan, location: startLocation)
        case ">":
            advance()
            return SPICEToken.Located(token: .greaterThan, location: startLocation)
        case "!":
            advance()
            return SPICEToken.Located(token: .exclamation, location: startLocation)
        case "&":
            advance()
            return SPICEToken.Located(token: .ampersand, location: startLocation)
        case "|":
            advance()
            return SPICEToken.Located(token: .pipe, location: startLocation)
        case "?":
            advance()
            return SPICEToken.Located(token: .question, location: startLocation)
        case ":":
            advance()
            return SPICEToken.Located(token: .colon, location: startLocation)
        case ";":
            advance()
            return SPICEToken.Located(token: .semicolon, location: startLocation)
        case "$":
            // ngspice inline comment
            return scanLineComment(startLocation: startLocation)
        default:
            // Skip unknown characters
            advance()
            return nextToken()
        }
    }

    // MARK: - Scanning Helpers

    private mutating func scanDirective(startLocation: SourceLocation) -> SPICEToken.Located {
        advance() // skip .
        var name = ""
        while !isAtEnd && (current.isLetter || current.isNumber || current == "_") {
            name.append(current)
            advance()
        }
        return SPICEToken.Located(
            token: .directive(name.lowercased()),
            location: startLocation
        )
    }

    private mutating func scanDotOperator(startLocation: SourceLocation) -> SPICEToken.Located? {
        let operators = ["eq", "ne", "le", "ge", "lt", "gt", "and", "or", "not"]
        for name in operators {
            let pattern = ".\(name)."
            if source[index...].lowercased().hasPrefix(pattern) {
                for _ in pattern {
                    advance()
                }
                return SPICEToken.Located(token: .dotOperator(name), location: startLocation)
            }
        }
        return nil
    }

    private mutating func scanNumber(startLocation: SourceLocation) -> SPICEToken.Located {
        var numberStr = ""

        // Handle optional sign
        if current == "+" || current == "-" {
            numberStr.append(current)
            advance()
        }

        // Integer part
        while !isAtEnd && current.isNumber {
            numberStr.append(current)
            advance()
        }

        // Decimal part
        if !isAtEnd && current == "." {
            numberStr.append(current)
            advance()
            while !isAtEnd && current.isNumber {
                numberStr.append(current)
                advance()
            }
        }

        // Exponent part
        if !isAtEnd && (current == "e" || current == "E") {
            numberStr.append(current)
            advance()
            if !isAtEnd && (current == "+" || current == "-") {
                numberStr.append(current)
                advance()
            }
            var exponentDigits = 0
            while !isAtEnd && current.isNumber {
                numberStr.append(current)
                advance()
                exponentDigits += 1
            }
            if exponentDigits == 0 {
                return SPICEToken.Located(token: .invalidNumericLiteral(numberStr), location: startLocation)
            }
        }

        let suffix = scanScaleSuffix()
        guard let scale = suffix.scale else {
            return SPICEToken.Located(token: .invalidNumericSuffix(suffix.text), location: startLocation)
        }
        guard let parsedValue = Double(numberStr) else {
            return SPICEToken.Located(token: .invalidNumericLiteral(numberStr), location: startLocation)
        }
        let value = parsedValue * scale

        return SPICEToken.Located(token: .number(value), location: startLocation)
    }

    private mutating func scanScaleSuffix() -> (text: String, scale: Double?) {
        let start = index
        while !isAtEnd, current.isLetter {
            advance()
        }

        let suffix = String(source[start..<index]).lowercased()
        guard !suffix.isEmpty else {
            return (suffix, 1.0)
        }
        if suffix.hasPrefix("meg") {
            return (suffix, 1e6)
        }
        if suffix.hasPrefix("mil") {
            return (suffix, 25.4e-6)
        }

        switch suffix.first {
        case "t":
            return (suffix, 1e12)
        case "g":
            return (suffix, 1e9)
        case "x":
            return (suffix, 1e6)
        case "k":
            return (suffix, 1e3)
        case "m":
            return (suffix, 1e-3)
        case "u":
            return (suffix, 1e-6)
        case "n":
            return (suffix, 1e-9)
        case "p":
            return (suffix, 1e-12)
        case "f":
            return (suffix, 1e-15)
        case "a":
            return (suffix, 1e-18)
        default:
            return (suffix, nil)
        }
    }

    private mutating func scanIdentifier(startLocation: SourceLocation) -> SPICEToken.Located {
        var name = ""
        while !isAtEnd && (current.isLetter || current.isNumber || current == "_" || current == ":" || current == ".") {
            name.append(current)
            advance()
        }

        // Check if it's a number with suffix (like 1k)
        if let firstChar = name.first, firstChar.isNumber {
            // This is actually a number that started with a letter-like character
            if let value = Double(name) {
                return SPICEToken.Located(token: .number(value), location: startLocation)
            }
        }

        return SPICEToken.Located(
            token: .identifier(configuration.caseInsensitive ? name.lowercased() : name),
            location: startLocation
        )
    }

    private mutating func scanString(startLocation: SourceLocation) -> SPICEToken.Located {
        let quote = current
        advance() // skip opening quote

        var value = ""
        while !isAtEnd && current != quote && current != "\n" {
            if current == "\\" && peek() == quote {
                advance()
            }
            value.append(current)
            advance()
        }

        if current == quote {
            advance() // skip closing quote
        }

        return SPICEToken.Located(token: .string(value), location: startLocation)
    }

    private mutating func scanLineComment(startLocation: SourceLocation) -> SPICEToken.Located {
        var comment = ""
        while !isAtEnd && current != "\n" {
            comment.append(current)
            advance()
        }
        return SPICEToken.Located(token: .comment(comment), location: startLocation)
    }

    private mutating func skipWhitespaceAndComments() {
        while !isAtEnd {
            let char = current

            // Skip spaces and tabs (but not newlines)
            if char == " " || char == "\t" || char == "\r" {
                advance()
                continue
            }

            // Skip inline comments ($)
            if char == "$" {
                while !isAtEnd && current != "\n" {
                    advance()
                }
                continue
            }

            // Skip ; comments to end of line
            if char == ";" {
                while !isAtEnd && current != "\n" {
                    advance()
                }
                continue
            }

            break
        }
    }

    // MARK: - Character Access

    private var isAtEnd: Bool {
        index >= source.endIndex
    }

    private var current: Character {
        source[index]
    }

    private func peek() -> Character? {
        let nextIndex = source.index(after: index)
        guard nextIndex < source.endIndex else { return nil }
        return source[nextIndex]
    }

    private mutating func advance() {
        if current == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
        index = source.index(after: index)
    }

    private var currentLocation: SourceLocation {
        SourceLocation(file: fileName ?? "<input>", line: line, column: column)
    }
}

extension Character {
    fileprivate func lowercased() -> String {
        String(self).lowercased()
    }
}

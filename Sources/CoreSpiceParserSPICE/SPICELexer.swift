import CoreSpiceParsedIR
import CoreSpiceParser

/// A lexer for SPICE netlist files.
///
/// The lexer converts raw source text into a stream of tokens
/// that the parser can consume.
public struct SPICELexer: Sendable {

    private var work: (any SPICESourceWorkAccounting)?
    private var scanStorage: SPICEParseStorage?
    private var workFailure: (any Error)?
    private var checkpointCharacters = 0
    private let source: String
    private let fileName: String?
    private let configuration: ParserConfiguration
    private var index: String.Index
    private var sourceEnd: String.Index
    private var elideModelNumericQuotes = false
    private var isLinePrefixWhitespace: Bool = true
    private var line: Int = 1
    private var column: Int = 1
    private var delimiterDepth = 0
    private var conditionalScopes = SPICEParserStack<Int>()
    private var pendingStatementBoundary = false

    public init(
        source: String,
        fileName: String? = nil,
        configuration: ParserConfiguration = .default
    ) {
        self.source = source
        self.fileName = fileName
        self.configuration = configuration
        self.index = source.startIndex
        self.sourceEnd = source.endIndex
    }

    /// Expression interiors have operators, not card continuation/comment prefixes.
    init(expressionSource: String, fileName: String?) {
        self.init(source: expressionSource, fileName: fileName)
        isLinePrefixWhitespace = false
    }

    /// Borrows the original model span; quote spaces retain physical coordinates.
    init(modelExpressionSource: String, range: Range<String.Index>, opening: SourceLocation,
         configuration: ParserConfiguration = .default) {
        self.init(source: modelExpressionSource, fileName: opening.file, configuration: configuration)
        index = range.lowerBound
        sourceEnd = range.upperBound
        line = opening.line
        column = opening.column
        isLinePrefixWhitespace = false
        elideModelNumericQuotes = true
    }

    /// Tokenizes the entire source.
    public mutating func tokenize() -> [SPICEToken.Located] {
        do { return try tokenizeChecked(work: nil) }
        catch { preconditionFailure("Unaccounted lexing cannot produce a work failure") }
    }

    /// Token storage is charged before scanning; cancellation is cooperative even inside long tokens.
    public mutating func tokenizeChecked(work: (any SPICESourceWorkAccounting)?) throws -> [SPICEToken.Located] {
        self.work = work
        defer { resetExpressionScope() }
        try work?.checkCancellation()
        try work?.charge(.lexicalBytes, units: UInt64(source[index..<sourceEnd].utf8.count))
        var tokens: [SPICEToken.Located] = []
        var statementEnd: Int?
        while !isAtEnd {
            try work?.charge(.tokens, units: 1)
            if let token = nextToken() {
                if let workFailure { throw workFailure }
                switch token.token {
                case .continuation:
                    if let statementEnd { tokens.removeSubrange(statementEnd..<tokens.count) }
                    else { tokens.append(token) }
                case .newline, .comment: tokens.append(token)
                default:
                    tokens.append(token)
                    statementEnd = tokens.count
                }
            }
        }
        if let workFailure { throw workFailure }
        try work?.charge(.tokens, units: 1)
        tokens.append(SPICEToken.Located(token: .endOfFile, location: currentLocation))
        return tokens
    }

    /// Uses the same scanners with admitted string and concrete token-slot storage.
    mutating func tokenizeOwned(resources: any SPICESourceResourceAccounting) throws -> SPICEOwnedTokens {
        work = resources
        workFailure = nil
        try resources.checkCancellation()
        var byteCount: UInt64 = 0
        for byte in source[index..<sourceEnd].utf8 {
            if byteCount.isMultiple(of: 256) { try resources.checkCancellation() }
            try resources.charge(.lexicalBytes, units: 1)
            guard byte < 128 else {
                throw SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode SPICE lexing")
            }
            byteCount += 1
        }
        var lexemes = SPICEAccountedCollection<OwnedLexeme>(storageKind: .temporaryBytes)
        var statementEnd: Int?
        defer { scanStorage = nil; resetExpressionScope() }
        while !isAtEnd {
            try resources.charge(.tokens, units: 1)
            if lexemes.count == lexemes.managedCapacity {
                let (doubled, overflow) = lexemes.managedCapacity.multipliedReportingOverflow(by: 2)
                guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
                try lexemes.reserveCapacity(Swift.max(1, doubled), resources: resources)
            }
            scanStorage = SPICEParseStorage(resources: resources)
            let token = nextToken()
            if let workFailure { throw workFailure }
            guard let token else { scanStorage = nil; continue }
            guard let payload = scanStorage else { preconditionFailure("Missing lexer storage") }
            scanStorage = nil
            switch token.token {
            case .continuation:
                if let statementEnd {
                    var kept = SPICEAccountedCollection<OwnedLexeme>(storageKind: .temporaryBytes)
                    try kept.reserveCapacity(statementEnd, resources: resources)
                    for position in 0..<statementEnd {
                        try kept.append(lexemes[position], resources: resources)
                    }
                    lexemes.removeAll()
                    lexemes = kept
                } else { try lexemes.append(OwnedLexeme(token: token, storage: payload), resources: resources) }
            case .newline, .comment:
                try lexemes.append(OwnedLexeme(token: token, storage: payload), resources: resources)
            default:
                try lexemes.append(OwnedLexeme(token: token, storage: payload), resources: resources)
                statementEnd = lexemes.count
            }
        }
        if let workFailure { throw workFailure }
        try resources.charge(.tokens, units: 1)
        var storage = SPICEParseStorage(resources: resources)
        var tokens = SPICEAccountedCollection<SPICEToken.Located>(storageKind: .temporaryBytes)
        let (count, overflow) = lexemes.count.addingReportingOverflow(1)
        guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
        try tokens.reserveCapacity(count, resources: resources)
        for position in lexemes.indices {
            try tokens.append(lexemes[position].token, resources: resources)
            try storage.hold(lexemes[position].storage)
        }
        try tokens.append(SPICEToken.Located(token: .endOfFile, location: currentLocation), resources: resources)
        let output = try storage.ownArray(tokens)
        tokens.removeAll()
        lexemes.removeAll()
        try resources.checkCancellation()
        return SPICEOwnedTokens(tokens: output, storage: storage)
    }

    private struct OwnedLexeme: Sendable {
        let token: SPICEToken.Located
        let storage: SPICEParseStorage
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
        if isAtNewline {
            pendingStatementBoundary = true
            advance()
            return SPICEToken.Located(token: .newline, location: startLocation)
        }

        // Handle continuation at start of line (after newline)
        if char == "+" && isLinePrefixWhitespace {
            pendingStatementBoundary = false
            advance()
            return SPICEToken.Located(token: .continuation, location: startLocation)
        }

        if char == "*" && isLinePrefixWhitespace {
            return scanLineComment(startLocation: startLocation)
        }
        if pendingStatementBoundary { resetExpressionScope() }

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
            enterDelimiter()
            advance()
            return SPICEToken.Located(token: .leftParen, location: startLocation)
        case ")":
            leaveDelimiter()
            advance()
            return SPICEToken.Located(token: .rightParen, location: startLocation)
        case "{":
            enterDelimiter()
            advance()
            return SPICEToken.Located(token: .leftBrace, location: startLocation)
        case "}":
            leaveDelimiter()
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
            if isLinePrefixWhitespace {
                return scanLineComment(startLocation: startLocation)
            }
            advance()
            // Check for ** (power)
            if !isAtEnd && current == "*" {
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
            beginConditional()
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
            advance()
            return SPICEToken.Located(token: .invalidCharacter(char), location: startLocation)
        }
    }

    // MARK: - Scanning Helpers

    private mutating func scanDirective(startLocation: SourceLocation) -> SPICEToken.Located {
        advance() // skip .
        let start = index
        while !isAtEnd && (current.isLetter || current.isNumber || current == "_") { advance() }
        return SPICEToken.Located(token: .directive(materialize(start..<index, lowercase: true)),
                                 location: startLocation)
    }

    private mutating func scanDotOperator(startLocation: SourceLocation) -> SPICEToken.Located? {
        if let token = matchDotOperator(".eq.", name: "eq", at: startLocation) { return token }
        if let token = matchDotOperator(".ne.", name: "ne", at: startLocation) { return token }
        if let token = matchDotOperator(".le.", name: "le", at: startLocation) { return token }
        if let token = matchDotOperator(".ge.", name: "ge", at: startLocation) { return token }
        if let token = matchDotOperator(".lt.", name: "lt", at: startLocation) { return token }
        if let token = matchDotOperator(".gt.", name: "gt", at: startLocation) { return token }
        if let token = matchDotOperator(".and.", name: "and", at: startLocation) { return token }
        if let token = matchDotOperator(".or.", name: "or", at: startLocation) { return token }
        return matchDotOperator(".not.", name: "not", at: startLocation)
    }

    private mutating func matchDotOperator(_ pattern: String, name: String,
                                          at location: SourceLocation) -> SPICEToken.Located? {
        var probe = index
        for expected in pattern.utf8 {
            do { try work?.checkCancellation(); try work?.charge(.lexicalBytes, units: 1) }
            catch { workFailure = error; return nil }
            guard probe < source.endIndex, let actual = source[probe].asciiValue,
                  (actual >= 65 && actual <= 90 ? actual + 32 : actual) == expected else { return nil }
            probe = source.index(after: probe)
        }
        for _ in pattern { advance() }
        return SPICEToken.Located(token: .dotOperator(name), location: location)
    }

    private mutating func scanNumber(startLocation: SourceLocation) -> SPICEToken.Located {
        let start = index

        // Handle optional sign
        if current == "+" || current == "-" {
            advance()
        }

        // Integer part
        while !isAtEnd && current.isNumber {
            advance()
        }

        // Decimal part
        if !isAtEnd && current == "." {
            advance()
            while !isAtEnd && current.isNumber {
                advance()
            }
        }

        // Preserve semantic version identity rather than emitting two numbers.
        if !isAtEnd && current == "." {
            while !isAtEnd && (current.isNumber || current == ".") {
                advance()
            }
            return SPICEToken.Located(token: .dottedLiteral(materialize(start..<index)), location: startLocation)
        }

        // Exponent part
        if !isAtEnd && (current == "e" || current == "E") {
            advance()
            if !isAtEnd && (current == "+" || current == "-") {
                advance()
            }
            var exponentDigits = 0
            while !isAtEnd && current.isNumber {
                advance()
                exponentDigits += 1
            }
            if exponentDigits == 0 {
                return SPICEToken.Located(token: .invalidNumericLiteral(materialize(start..<index)), location: startLocation)
            }
        }

        let numericEnd = index
        let suffix = scanScaleSuffix()
        let numberStr = materialize(start..<numericEnd)
        if scanStorage != nil && numberStr.utf8.count > 64 {
            workFailure = SPICEBoundedSourceError.unsupportedBudgetCapability("Scalar decimal conversion beyond 64 ASCII bytes")
            return SPICEToken.Located(token: .invalidNumericLiteral(numberStr), location: startLocation)
        }
        guard let scale = suffix.scale else {
            return SPICEToken.Located(token: .invalidNumericSuffix(suffix.text), location: startLocation)
        }
        let conversionScratch: SPICESourceStorageReservation?
        if let resources = scanStorage?.resources {
            do {
                // The installed Double(String) initializer uses a NUL-terminated C string.
                // The admitted scalar input is at most the backend's 64-byte formatting extent.
                try resources.checkCancellation()
                conversionScratch = try resources.reserveStorage(kind: .temporaryBytes,
                    byteCount: UInt64(numberStr.utf8.count) + 1)
                try resources.charge(.lexicalBytes, units: UInt64(numberStr.utf8.count))
            } catch {
                workFailure = error
                return SPICEToken.Located(token: .invalidNumericLiteral(numberStr), location: startLocation)
            }
        } else { conversionScratch = nil }
        defer { withExtendedLifetime(conversionScratch) {} }
        guard let parsedValue = Double(numberStr), parsedValue.isFinite else {
            return SPICEToken.Located(token: .invalidNumericLiteral(numberStr), location: startLocation)
        }
        let value = parsedValue * scale
        guard value.isFinite else {
            return SPICEToken.Located(token: .invalidNumericLiteral(materialize(start..<index, lowercase: true)), location: startLocation)
        }

        return SPICEToken.Located(token: .number(value), location: startLocation)
    }

    private mutating func scanScaleSuffix() -> (text: String, scale: Double?) {
        let start = index
        while !isAtEnd, current.isLetter {
            advance()
        }

        let suffix = materialize(start..<index, lowercase: true)
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
        let start = index
        while !isAtEnd && (current.isLetter || current.isNumber || current == "_" || current == ":" || current == ".") {
            if current == ":", conditionalScopes.last == delimiterDepth { break }
            advance()
        }
        return SPICEToken.Located(token: .identifier(materialize(start..<index,
            lowercase: configuration.caseInsensitive)), location: startLocation)
    }

    private mutating func resetExpressionScope() {
        conditionalScopes = SPICEParserStack()
        delimiterDepth = 0
        pendingStatementBoundary = false
    }

    private mutating func enterDelimiter() {
        let (next, overflow) = delimiterDepth.addingReportingOverflow(1)
        if overflow { workFailure = SPICESourceStorageError.arithmeticOverflow }
        else { delimiterDepth = next }
    }

    private mutating func leaveDelimiter() {
        if delimiterDepth > 0 { delimiterDepth -= 1 }
        do {
            while let depth = conditionalScopes.last, depth > delimiterDepth {
                _ = try conditionalScopes.removeLast(resources: scanStorage?.resources)
            }
        } catch { workFailure = error }
    }

    private mutating func beginConditional() {
        guard conditionalScopes.last != delimiterDepth else { return }
        do {
            let resources = scanStorage?.resources
            if resources == nil { try work?.charge(.retainedElements, units: 1) }
            // Retain the depth until scope exit so an extra colon remains punctuation.
            try conditionalScopes.append(delimiterDepth, resources: resources)
        } catch { workFailure = error }
    }

    private mutating func scanString(startLocation: SourceLocation) -> SPICEToken.Located {
        let quote = current
        advance() // skip opening quote

        let start = index
        while !isAtEnd && current != quote && !isAtNewline {
            if current == "\\", peek() == quote || peek() == "\\" { advance() }
            advance()
        }
        guard !isAtEnd && current == quote else {
            return SPICEToken.Located(token: .unterminatedQuote, location: startLocation)
        }
        let end = index
        advance()
        let value = materialize(start..<end, decodeDelimiter: quote == "\"" ? quote : nil)
        return SPICEToken.Located(token: quote == "'" ? .quotedExpression(value) : .string(value), location: startLocation)
    }

    /// Decodes only delimiter/backslash escapes; all other source text stays exact.
    static func decodeQuotedText(_ text: String, delimiter: Character) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\\", next < text.endIndex,
               text[next] == delimiter || text[next] == "\\" {
                result.append(text[next])
                index = text.index(after: next)
            } else {
                result.append(character)
                index = next
            }
        }
        return result
    }

    private mutating func scanLineComment(startLocation: SourceLocation) -> SPICEToken.Located {
        let start = index
        while !isAtEnd && !isAtNewline { advance() }
        return SPICEToken.Located(token: .comment(materialize(start..<index)), location: startLocation)
    }

    /// ASCII was validated before bounded scanning, so case folding never expands UTF-8.
    private mutating func materialize(_ range: Range<String.Index>, lowercase: Bool = false,
                                     decodeDelimiter: Character? = nil) -> String {
        guard var storage = scanStorage else {
            let text = String(source[range])
            if let decodeDelimiter { return Self.decodeQuotedText(text, delimiter: decodeDelimiter) }
            return lowercase ? text.lowercased() : text
        }
        scanStorage = nil
        defer { scanStorage = storage }
        do {
            var count = 0
            var probe = range.lowerBound
            while probe < range.upperBound {
                if count.isMultiple(of: 256) { try storage.resources.checkCancellation() }
                try storage.resources.charge(.lexicalBytes, units: 1)
                let character = source[probe]
                probe = source.index(after: probe)
                if let decodeDelimiter, character == "\\", probe < range.upperBound,
                   source[probe] == decodeDelimiter || source[probe] == "\\" { probe = source.index(after: probe) }
                count += 1
            }
            let receipt = try storage.resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(count))
            try storage.resources.charge(.projectedBytes, units: UInt64(count))
            var output = ""
            output.reserveCapacity(count)
            probe = range.lowerBound
            var copied = 0
            while probe < range.upperBound {
                if copied.isMultiple(of: 256) { try storage.resources.checkCancellation() }
                var character = source[probe]
                probe = source.index(after: probe)
                if let decodeDelimiter, character == "\\", probe < range.upperBound,
                   source[probe] == decodeDelimiter || source[probe] == "\\" {
                    character = source[probe]; probe = source.index(after: probe)
                }
                if lowercase, let ascii = character.asciiValue, ascii >= 65 && ascii <= 90 {
                    character = Character(UnicodeScalar(ascii + 32))
                }
                output.append(character)
                copied += 1
            }
            try storage.resources.checkCancellation()
            try storage.retain(output, reservation: receipt)
            return output
        } catch { workFailure = error; return "" }
    }

    private mutating func skipWhitespaceAndComments() {
        while !isAtEnd {
            let char = current

            // Skip spaces and tabs (but not newlines)
            if char == " " || char == "\t" || char == "\r" || (elideModelNumericQuotes && char == "\"") {
                advance()
                continue
            }

            // Skip inline comments ($)
            if char == "$" {
                while !isAtEnd && !isAtNewline {
                    advance()
                }
                continue
            }

            // Skip ; comments to end of line
            if char == ";" {
                while !isAtEnd && !isAtNewline {
                    advance()
                }
                continue
            }

            break
        }
    }

    // MARK: - Character Access

    private var isAtEnd: Bool {
        workFailure != nil || index >= sourceEnd
    }

    private var current: Character {
        source[index]
    }

    private var isAtNewline: Bool {
        current == "\n" || current == "\r\n"
    }

    private func peek() -> Character? {
        let nextIndex = source.index(after: index)
        guard nextIndex < sourceEnd else { return nil }
        return source[nextIndex]
    }

    private mutating func advance() {
        guard !isAtEnd else { return }
        checkpointCharacters += 1
        if checkpointCharacters == 256 {
            checkpointCharacters = 0
            do { try work?.checkCancellation() }
            catch { workFailure = error; return }
        }
        if isAtNewline {
            line += 1
            column = 1
            isLinePrefixWhitespace = true
        } else {
            column += 1
            if !current.isWhitespace && !(elideModelNumericQuotes && current == "\"") {
                isLinePrefixWhitespace = false
            }
        }
        index = source.index(after: index)
    }

    private var currentLocation: SourceLocation {
        SourceLocation(file: fileName ?? "<input>", line: line, column: column)
    }
}

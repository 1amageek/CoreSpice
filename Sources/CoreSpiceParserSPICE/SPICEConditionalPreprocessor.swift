import CoreSpiceParsedIR
import CoreSpiceParser
import Foundation

/// Applies SPICE conditional deck directives before token parsing.
struct SPICEConditionalPreprocessor: Sendable {

    struct Result: Sendable {
        let source: String
        let events: [SPICEPreprocessingEvent]
        let diagnostics: [ParserDiagnostic]
    }

    func process(
        source: String,
        fileName: String?,
        initialParameters: [String: String] = [:]
    ) -> Result {
        var processor = Processor(
            source: source,
            fileName: fileName,
            initialParameters: initialParameters
        )
        return processor.process()
    }
}

private struct Processor {

    private struct ConditionalFrame {
        let parentActive: Bool
        let openingLocation: SourceLocation
        var branchActive: Bool
        var branchTaken: Bool
        var hasElse: Bool
    }

    private let source: String
    private let fileName: String?
    private var frames: [ConditionalFrame] = []
    private var parameterScopes: [[String: String]]
    private var functionScopes: [[String: ConditionalFunctionDefinition]]
    private var outputLines: [String] = []
    private var events: [SPICEPreprocessingEvent] = []
    private var diagnostics: [ParserDiagnostic] = []

    init(source: String, fileName: String?, initialParameters: [String: String]) {
        self.source = source
        self.fileName = fileName
        let rootScope = initialParameters.reduce(into: [:]) { result, entry in
            result[entry.key.lowercased()] = entry.value
        }
        self.parameterScopes = [rootScope]
        self.functionScopes = [[:]]
    }

    mutating func process() -> SPICEConditionalPreprocessor.Result {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        outputLines.reserveCapacity(lines.count)

        for (offset, line) in lines.enumerated() {
            process(line: line, lineNumber: offset + 1)
        }

        for frame in frames.reversed() {
            diagnostics.append(.error("Unterminated SPICE conditional block", at: frame.openingLocation))
        }

        return SPICEConditionalPreprocessor.Result(
            source: outputLines.joined(separator: "\n"),
            events: events,
            diagnostics: diagnostics
        )
    }

    private mutating func process(line: String, lineNumber: Int) {
        guard let directive = ConditionalDirective(line: line, fileName: fileName, lineNumber: lineNumber) else {
            if currentActive {
                outputLines.append(line)
                updateScopeIfNeeded(from: line)
            } else {
                outputLines.append("")
            }
            return
        }

        outputLines.append("")

        switch directive.kind {
        case .ifStatement:
            processIf(directive)
        case .elseIf, .elseIfAlias:
            processElseIf(directive)
        case .elseStatement:
            processElse(directive)
        case .endIf:
            processEndIf(directive)
        }
    }

    private mutating func processIf(_ directive: ConditionalDirective) {
        let parentActive = currentActive
        var branchActive = false
        var branchTaken = false

        if parentActive {
            switch evaluateCondition(directive.expression, location: directive.location) {
            case .success(let active):
                branchActive = active
                branchTaken = active
            case .failure:
                branchActive = false
                branchTaken = true
            }
        }

        frames.append(ConditionalFrame(
            parentActive: parentActive,
            openingLocation: directive.location,
            branchActive: parentActive && branchActive,
            branchTaken: branchTaken,
            hasElse: false
        ))
        events.append(SPICEPreprocessingEvent(
            kind: directive.kind,
            expression: directive.expression,
            active: parentActive && branchActive,
            location: directive.location
        ))
    }

    private mutating func processElseIf(_ directive: ConditionalDirective) {
        guard !frames.isEmpty else {
            diagnostics.append(.error(".\(directive.kind.rawValue) without matching .if", at: directive.location))
            events.append(SPICEPreprocessingEvent(
                kind: directive.kind,
                expression: directive.expression,
                active: false,
                location: directive.location
            ))
            return
        }

        var frame = frames.removeLast()
        if frame.hasElse {
            diagnostics.append(.error(".\(directive.kind.rawValue) cannot appear after .else", at: directive.location))
            frame.branchActive = false
            frames.append(frame)
            events.append(SPICEPreprocessingEvent(
                kind: directive.kind,
                expression: directive.expression,
                active: false,
                location: directive.location
            ))
            return
        }

        var branchActive = false
        if frame.parentActive && !frame.branchTaken {
            switch evaluateCondition(directive.expression, location: directive.location) {
            case .success(let active):
                branchActive = active
                if active {
                    frame.branchTaken = true
                }
            case .failure:
                branchActive = false
                frame.branchTaken = true
            }
        }

        frame.branchActive = frame.parentActive && branchActive
        frames.append(frame)
        events.append(SPICEPreprocessingEvent(
            kind: directive.kind,
            expression: directive.expression,
            active: frame.parentActive && branchActive,
            location: directive.location
        ))
    }

    private mutating func processElse(_ directive: ConditionalDirective) {
        guard !frames.isEmpty else {
            diagnostics.append(.error(".else without matching .if", at: directive.location))
            events.append(SPICEPreprocessingEvent(
                kind: directive.kind,
                expression: nil,
                active: false,
                location: directive.location
            ))
            return
        }

        var frame = frames.removeLast()
        if frame.hasElse {
            diagnostics.append(.error("Duplicate .else in SPICE conditional block", at: directive.location))
            frame.branchActive = false
        } else {
            frame.hasElse = true
            frame.branchActive = frame.parentActive && !frame.branchTaken
            frame.branchTaken = true
        }
        let active = frame.branchActive
        frames.append(frame)
        events.append(SPICEPreprocessingEvent(
            kind: directive.kind,
            expression: nil,
            active: active,
            location: directive.location
        ))
    }

    private mutating func processEndIf(_ directive: ConditionalDirective) {
        guard let frame = frames.popLast() else {
            diagnostics.append(.error(".endif without matching .if", at: directive.location))
            events.append(SPICEPreprocessingEvent(
                kind: directive.kind,
                expression: nil,
                active: false,
                location: directive.location
            ))
            return
        }

        events.append(SPICEPreprocessingEvent(
            kind: directive.kind,
            expression: nil,
            active: frame.branchActive,
            location: directive.location
        ))
    }

    private mutating func updateScopeIfNeeded(from line: String) {
        guard let directive = ParsedLineDirective(line: line) else {
            return
        }

        switch directive.keyword {
        case "subckt":
            parameterScopes.append(subcircuitParameters(from: directive.body))
            functionScopes.append([:])
        case "ends":
            if parameterScopes.count > 1 {
                parameterScopes.removeLast()
            }
            if functionScopes.count > 1 {
                functionScopes.removeLast()
            }
        case "param":
            applyParameterAssignments(ParameterAssignmentParser.parse(directive.body))
        case "func", "function":
            applyFunctionDefinition(FunctionDefinitionParser.parse(directive.body))
        default:
            break
        }
    }

    private mutating func applyParameterAssignments(_ assignments: [ParameterAssignment]) {
        guard !parameterScopes.isEmpty else {
            parameterScopes.append([:])
            applyParameterAssignments(assignments)
            return
        }

        let scopeIndex = parameterScopes.count - 1
        for assignment in assignments {
            parameterScopes[scopeIndex][assignment.name.lowercased()] = assignment.expression
        }
    }

    private mutating func applyFunctionDefinition(_ definition: ConditionalFunctionDefinition?) {
        guard let definition else {
            return
        }
        guard !functionScopes.isEmpty else {
            functionScopes.append([definition.name: definition])
            return
        }

        let scopeIndex = functionScopes.count - 1
        functionScopes[scopeIndex][definition.name] = definition
    }

    private func subcircuitParameters(from body: String) -> [String: String] {
        let fields = body.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let paramsIndex = fields.firstIndex(where: { field in
            let lower = field.lowercased()
            return lower == "params:" || lower == "params"
        }) else {
            return [:]
        }

        let parameterText = fields[(paramsIndex + 1)...].joined(separator: " ")
        return ParameterAssignmentParser.parse(parameterText).reduce(into: [:]) { result, assignment in
            result[assignment.name.lowercased()] = assignment.expression
        }
    }

    private mutating func evaluateCondition(
        _ expression: String?,
        location: SourceLocation
    ) -> Result<Bool, SPICEConditionalExpressionError> {
        guard let expression, !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let error = SPICEConditionalExpressionError(message: "Missing condition expression")
            diagnostics.append(.error("Invalid SPICE conditional expression: \(error.message)", at: location))
            return .failure(error)
        }

        do {
            let parsedExpression = try SPICEExpressionParser().parse(expression, fileName: location.file)
            var evaluator = SPICEConditionalExpressionEvaluator(
                parameters: mergedParameterExpressions,
                parameterValues: [:],
                functions: mergedFunctionDefinitions,
                resolvingParameters: [],
                resolvingFunctions: []
            )
            let value = try evaluator.evaluate(parsedExpression)
            return .success(value != 0)
        } catch let diagnostic as ParserDiagnostic {
            let error = SPICEConditionalExpressionError(message: diagnostic.message)
            diagnostics.append(.error("Invalid SPICE conditional expression: \(error.message)", at: location))
            return .failure(error)
        } catch let error as SPICEConditionalExpressionError {
            diagnostics.append(.error("Invalid SPICE conditional expression: \(error.message)", at: location))
            return .failure(error)
        } catch {
            let wrapped = SPICEConditionalExpressionError(message: "\(error)")
            diagnostics.append(.error("Invalid SPICE conditional expression: \(wrapped.message)", at: location))
            return .failure(wrapped)
        }
    }

    private var currentActive: Bool {
        frames.last?.branchActive ?? true
    }

    private var mergedParameterExpressions: [String: String] {
        parameterScopes.reduce(into: [:]) { result, scope in
            for (name, expression) in scope {
                result[name] = expression
            }
        }
    }

    private var mergedFunctionDefinitions: [String: ConditionalFunctionDefinition] {
        functionScopes.reduce(into: [:]) { result, scope in
            for (name, definition) in scope {
                result[name] = definition
            }
        }
    }
}

private struct ConditionalDirective {
    let kind: SPICEConditionalDirectiveKind
    let expression: String?
    let location: SourceLocation

    init?(line: String, fileName: String?, lineNumber: Int) {
        guard let parsed = ParsedLineDirective(line: line),
              let kind = SPICEConditionalDirectiveKind(rawValue: parsed.keyword) else {
            return nil
        }
        self.kind = kind
        let uncommentedBody = SPICEInlineCommentStripper.strip(from: parsed.body)
        let trimmedBody = uncommentedBody.trimmingCharacters(in: .whitespacesAndNewlines)
        expression = trimmedBody.isEmpty ? nil : trimmedBody
        location = SourceLocation(file: fileName ?? "<input>", line: lineNumber, column: parsed.directiveColumn)
    }
}

private struct ParsedLineDirective {
    let keyword: String
    let body: String
    let directiveColumn: Int

    init?(line: String) {
        var index = line.startIndex
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == "." else {
            return nil
        }

        let directiveColumn = line.distance(from: line.startIndex, to: index) + 1
        index = line.index(after: index)
        let keywordStart = index
        while index < line.endIndex, Self.isDirectiveCharacter(line[index]) {
            index = line.index(after: index)
        }
        guard keywordStart < index else {
            return nil
        }

        keyword = String(line[keywordStart..<index]).lowercased()
        let bodyStart = index
        body = String(line[bodyStart...])
        self.directiveColumn = directiveColumn
    }

    private static func isDirectiveCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}

private struct ParameterAssignment {
    let name: String
    let expression: String
}

private struct ConditionalFunctionDefinition: Sendable, Hashable {
    let name: String
    let parameters: [String]
    let body: String
}

private struct FunctionDefinitionParser {

    static func parse(_ body: String) -> ConditionalFunctionDefinition? {
        let text = SPICEInlineCommentStripper.strip(from: body)
        var index = text.startIndex
        skipWhitespace(in: text, index: &index)

        guard let name = readIdentifier(in: text, index: &index) else {
            return nil
        }
        skipWhitespace(in: text, index: &index)
        guard index < text.endIndex, text[index] == "(" else {
            return nil
        }
        index = text.index(after: index)

        var parameters: [String] = []
        skipWhitespace(in: text, index: &index)
        if index < text.endIndex, text[index] != ")" {
            while true {
                skipWhitespace(in: text, index: &index)
                guard let parameter = readIdentifier(in: text, index: &index) else {
                    return nil
                }
                parameters.append(parameter.lowercased())
                skipWhitespace(in: text, index: &index)
                if index < text.endIndex, text[index] == ")" {
                    break
                }
                guard index < text.endIndex, text[index] == "," else {
                    return nil
                }
                index = text.index(after: index)
            }
        }

        guard index < text.endIndex, text[index] == ")" else {
            return nil
        }
        index = text.index(after: index)
        skipWhitespace(in: text, index: &index)
        if index < text.endIndex, text[index] == "=" {
            index = text.index(after: index)
            skipWhitespace(in: text, index: &index)
        }

        let bodyText = String(text[index...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bodyText.isEmpty else {
            return nil
        }

        return ConditionalFunctionDefinition(
            name: name.lowercased(),
            parameters: parameters,
            body: ParameterAssignmentParser.stripOuterBraces(bodyText)
        )
    }

    private static func readIdentifier(in text: String, index: inout String.Index) -> String? {
        guard index < text.endIndex, isIdentifierStart(text[index]) else {
            return nil
        }
        let start = index
        index = text.index(after: index)
        while index < text.endIndex, isIdentifierCharacter(text[index]) {
            index = text.index(after: index)
        }
        return String(text[start..<index])
    }

    private static func skipWhitespace(in text: String, index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "." || character == ":"
    }
}

private struct ParameterAssignmentParser {

    static func parse(_ body: String) -> [ParameterAssignment] {
        let text = SPICEInlineCommentStripper.strip(from: body)
        var assignments: [ParameterAssignment] = []
        var index = text.startIndex

        while index < text.endIndex {
            skipWhitespace(in: text, index: &index)
            guard let name = readIdentifier(in: text, index: &index) else {
                break
            }
            skipWhitespace(in: text, index: &index)
            guard index < text.endIndex, text[index] == "=" else {
                continue
            }
            index = text.index(after: index)
            skipWhitespace(in: text, index: &index)

            let valueStart = index
            readValue(in: text, index: &index)
            let value = String(text[valueStart..<index])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                assignments.append(ParameterAssignment(name: name, expression: stripOuterBraces(value)))
            }
        }

        return assignments
    }

    private static func readValue(in text: String, index: inout String.Index) {
        var braceDepth = 0
        var parenDepth = 0
        var quote: Character?

        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
                index = text.index(after: index)
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                index = text.index(after: index)
                continue
            }
            if character == "{" {
                braceDepth += 1
                index = text.index(after: index)
                continue
            }
            if character == "}", braceDepth > 0 {
                braceDepth -= 1
                index = text.index(after: index)
                continue
            }
            if character == "(" {
                parenDepth += 1
                index = text.index(after: index)
                continue
            }
            if character == ")", parenDepth > 0 {
                parenDepth -= 1
                index = text.index(after: index)
                continue
            }
            if character.isWhitespace, braceDepth == 0, parenDepth == 0 {
                let whitespaceStart = index
                var probe = index
                skipWhitespace(in: text, index: &probe)
                if startsAssignment(in: text, at: probe) {
                    index = whitespaceStart
                    return
                }
            }
            index = text.index(after: index)
        }
    }

    private static func startsAssignment(in text: String, at index: String.Index) -> Bool {
        var probe = index
        guard readIdentifier(in: text, index: &probe) != nil else {
            return false
        }
        skipWhitespace(in: text, index: &probe)
        return probe < text.endIndex && text[probe] == "="
    }

    private static func readIdentifier(in text: String, index: inout String.Index) -> String? {
        guard index < text.endIndex, isIdentifierStart(text[index]) else {
            return nil
        }
        let start = index
        index = text.index(after: index)
        while index < text.endIndex, isIdentifierCharacter(text[index]) {
            index = text.index(after: index)
        }
        return String(text[start..<index])
    }

    static func stripOuterBraces(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{", trimmed.last == "}" else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func skipWhitespace(in text: String, index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == ":" || character == "."
    }
}

private struct SPICEInlineCommentStripper {

    static func strip(from text: String) -> String {
        var result = ""
        var braceDepth = 0
        var parenDepth = 0
        var quote: Character?

        for character in text {
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
                result.append(character)
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                result.append(character)
                continue
            }
            if character == "{" {
                braceDepth += 1
            } else if character == "}", braceDepth > 0 {
                braceDepth -= 1
            } else if character == "(" {
                parenDepth += 1
            } else if character == ")", parenDepth > 0 {
                parenDepth -= 1
            } else if (character == "$" || character == ";"), braceDepth == 0, parenDepth == 0 {
                break
            }
            result.append(character)
        }

        return result
    }
}

private struct SPICEConditionalExpressionError: Error, Sendable {
    let message: String
}

private struct SPICEConditionalExpressionEvaluator {

    private let parameters: [String: String]
    private let parameterValues: [String: Double]
    private let functions: [String: ConditionalFunctionDefinition]
    private var resolvingParameters: Set<String>
    private var resolvingFunctions: Set<String>

    init(
        parameters: [String: String],
        parameterValues: [String: Double],
        functions: [String: ConditionalFunctionDefinition],
        resolvingParameters: Set<String>,
        resolvingFunctions: Set<String>
    ) {
        self.parameters = parameters
        self.parameterValues = parameterValues
        self.functions = functions
        self.resolvingParameters = resolvingParameters
        self.resolvingFunctions = resolvingFunctions
    }

    mutating func evaluate(_ expression: ParsedExpression) throws -> Double {
        switch expression {
        case .literal(let value):
            return value
        case .identifier(let name):
            return try resolveIdentifier(name.lowercased())
        case .unaryOperation(let operation, let expression):
            let value = try evaluate(expression)
            switch operation {
            case .negate:
                return -value
            case .not:
                return isTrue(value) ? 0 : 1
            case .plus:
                return value
            }
        case .binaryOperation(let operation, let lhs, let rhs):
            let left = try evaluate(lhs)
            let right = try evaluate(rhs)
            return try evaluateBinaryOperation(operation, left: left, right: right)
        case .functionCall(let name, let arguments):
            let values = try arguments.map { try evaluate($0) }
            return try evaluateFunction(name: name.lowercased(), arguments: values)
        case .conditional(let condition, let thenExpression, let elseExpression):
            if isTrue(try evaluate(condition)) {
                return try evaluate(thenExpression)
            }
            return try evaluate(elseExpression)
        }
    }

    private func evaluateBinaryOperation(
        _ operation: BinaryOperator,
        left: Double,
        right: Double
    ) throws -> Double {
        switch operation {
        case .add:
            return left + right
        case .subtract:
            return left - right
        case .multiply:
            return left * right
        case .divide:
            guard right != 0 else {
                throw SPICEConditionalExpressionError(message: "Division by zero")
            }
            return left / right
        case .power:
            return pow(left, right)
        case .modulo:
            guard right != 0 else {
                throw SPICEConditionalExpressionError(message: "Modulo by zero")
            }
            return left.truncatingRemainder(dividingBy: right)
        case .equal:
            return left == right ? 1 : 0
        case .notEqual:
            return left != right ? 1 : 0
        case .lessThan:
            return left < right ? 1 : 0
        case .lessOrEqual:
            return left <= right ? 1 : 0
        case .greaterThan:
            return left > right ? 1 : 0
        case .greaterOrEqual:
            return left >= right ? 1 : 0
        case .and:
            return isTrue(left) && isTrue(right) ? 1 : 0
        case .or:
            return isTrue(left) || isTrue(right) ? 1 : 0
        }
    }

    private mutating func resolveIdentifier(_ name: String) throws -> Double {
        switch name {
        case "true":
            return 1
        case "false":
            return 0
        case "pi":
            return Double.pi
        default:
            break
        }

        if let parameterValue = parameterValues[name] {
            return parameterValue
        }

        guard let parameterExpression = parameters[name] else {
            throw SPICEConditionalExpressionError(message: "Unknown conditional parameter '\(name)'")
        }
        guard !resolvingParameters.contains(name) else {
            throw SPICEConditionalExpressionError(message: "Recursive conditional parameter '\(name)'")
        }

        resolvingParameters.insert(name)
        let expression: ParsedExpression
        do {
            expression = try SPICEExpressionParser().parse(ParameterAssignmentParser.stripOuterBraces(parameterExpression))
        } catch let diagnostic as ParserDiagnostic {
            resolvingParameters.remove(name)
            throw SPICEConditionalExpressionError(message: diagnostic.message)
        }
        var evaluator = SPICEConditionalExpressionEvaluator(
            parameters: parameters,
            parameterValues: parameterValues,
            functions: functions,
            resolvingParameters: resolvingParameters,
            resolvingFunctions: resolvingFunctions
        )
        let value = try evaluator.evaluate(expression)
        resolvingParameters.remove(name)
        return value
    }

    private mutating func evaluateFunction(name: String, arguments: [Double]) throws -> Double {
        switch name {
        case "abs":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return abs(arguments[0])
        case "sgn", "sign":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return arguments[0] > 0 ? 1 : (arguments[0] < 0 ? -1 : 0)
        case "sqrt":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return sqrt(arguments[0])
        case "sin":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return sin(arguments[0])
        case "cos":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return cos(arguments[0])
        case "tan":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return tan(arguments[0])
        case "asin":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return asin(arguments[0])
        case "acos":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return acos(arguments[0])
        case "atan":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return atan(arguments[0])
        case "atan2":
            try requireArgumentCount(2, for: name, arguments: arguments)
            return atan2(arguments[0], arguments[1])
        case "sinh":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return sinh(arguments[0])
        case "cosh":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return cosh(arguments[0])
        case "tanh":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return tanh(arguments[0])
        case "exp":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return exp(arguments[0])
        case "log", "ln":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return log(arguments[0])
        case "log10":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return log10(arguments[0])
        case "min":
            try requireMinimumArgumentCount(2, for: name, arguments: arguments)
            return arguments.min() ?? 0
        case "max":
            try requireMinimumArgumentCount(2, for: name, arguments: arguments)
            return arguments.max() ?? 0
        case "pow":
            try requireArgumentCount(2, for: name, arguments: arguments)
            return pow(arguments[0], arguments[1])
        case "floor":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return floor(arguments[0])
        case "ceil":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return ceil(arguments[0])
        case "round", "nint":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return round(arguments[0])
        case "int":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return Double(Int(arguments[0]))
        case "if":
            try requireArgumentCount(3, for: name, arguments: arguments)
            return isTrue(arguments[0]) ? arguments[1] : arguments[2]
        case "limit":
            try requireArgumentCount(3, for: name, arguments: arguments)
            return Swift.min(Swift.max(arguments[0], arguments[1]), arguments[2])
        case "pwr", "pwrs":
            try requireArgumentCount(2, for: name, arguments: arguments)
            return pow(abs(arguments[0]), arguments[1])
        case "db":
            try requireArgumentCount(1, for: name, arguments: arguments)
            return 20 * log10(abs(arguments[0]))
        default:
            return try evaluateUserFunction(name: name, arguments: arguments)
        }
    }

    private func evaluateUserFunction(name: String, arguments: [Double]) throws -> Double {
        guard let function = functions[name] else {
            throw SPICEConditionalExpressionError(message: "Unsupported conditional function '\(name)'")
        }
        guard function.parameters.count == arguments.count else {
            throw SPICEConditionalExpressionError(
                message: "Function \(name) requires \(function.parameters.count) argument(s)"
            )
        }
        guard !resolvingFunctions.contains(name) else {
            throw SPICEConditionalExpressionError(message: "Recursive conditional function '\(name)'")
        }

        var scopedParameterValues = parameterValues
        for (parameter, argument) in zip(function.parameters, arguments) {
            scopedParameterValues[parameter] = argument
        }
        var nextResolvingFunctions = resolvingFunctions
        nextResolvingFunctions.insert(name)
        let expression: ParsedExpression
        do {
            expression = try SPICEExpressionParser().parse(function.body)
        } catch let diagnostic as ParserDiagnostic {
            throw SPICEConditionalExpressionError(message: diagnostic.message)
        }
        var evaluator = SPICEConditionalExpressionEvaluator(
            parameters: parameters,
            parameterValues: scopedParameterValues,
            functions: functions,
            resolvingParameters: resolvingParameters,
            resolvingFunctions: nextResolvingFunctions
        )
        return try evaluator.evaluate(expression)
    }

    private func requireArgumentCount(
        _ count: Int,
        for name: String,
        arguments: [Double]
    ) throws {
        guard arguments.count == count else {
            throw SPICEConditionalExpressionError(
                message: "Function \(name) requires \(count) argument(s)"
            )
        }
    }

    private func requireMinimumArgumentCount(
        _ count: Int,
        for name: String,
        arguments: [Double]
    ) throws {
        guard arguments.count >= count else {
            throw SPICEConditionalExpressionError(
                message: "Function \(name) requires at least \(count) argument(s)"
            )
        }
    }

    private func isTrue(_ value: Double) -> Bool {
        value != 0
    }
}

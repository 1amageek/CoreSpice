import CoreSpiceParsedIR
import CoreSpiceParser
import Foundation

/// Applies SPICE conditional deck directives before token parsing.
struct SPICEConditionalPreprocessor: Sendable {

    struct Result: Sendable {
        let source: String
        let events: [SPICEPreprocessingEvent]
        let diagnostics: [ParserDiagnostic]
        let storage: SPICEParseStorage?
    }

    func process(
        source: String,
        fileName: String?,
        initialParameters: [String: String] = [:],
        work: (any SPICESourceWorkAccounting)? = nil
    ) throws -> Result {
        var processor = try Processor(
            source: source,
            fileName: fileName,
            initialParameters: initialParameters,
            work: work
        )
        return try processor.process()
    }

    func processOwned(document: SPICESourceDocument, environment: SPICEPreprocessingEnvironment,
                      resources: any SPICESourceResourceAccounting) throws -> Result {
        guard document.isInvocationAccounted else { throw SPICEBoundedSourceError.unaccountedSource }
        var storage = SPICEParseStorage(resources: resources)
        try storage.hold(document)
        try storage.hold(environment)
        try ConditionalText.checkASCII(document.text, storage: storage)
        var processor = try Processor(source: document.text, fileName: document.resolvedPath,
            initialParameters: [:], work: resources, storage: storage, environment: environment)
        return try processor.process()
    }

}

private struct Processor {

    private struct ConditionalFrame: Sendable {
        let parentActive: Bool
        let openingLocation: SourceLocation
        var branchActive: Bool
        var branchTaken: Bool
        var hasElse: Bool
    }

    private let work: (any SPICESourceWorkAccounting)?
    private var workFailure: (any Error)?
    private var storage: SPICEParseStorage?
    private let inputOwner: SPICEParseStorage?
    private let source: String
    private let fileName: String?
    private var frames = SPICEParserStack<ConditionalFrame>()
    private var parameterScopes = SPICEParserStack<ConditionalMap<String>>()
    private var functionScopes = SPICEParserStack<ConditionalMap<ConditionalFunctionDefinition>>()
    private var outputLines = SPICEParserStack<String>()
    private var events = SPICEParserStack<SPICEPreprocessingEvent>()
    private var diagnostics = SPICEParserStack<ParserDiagnostic>()
    private var pendingSubcircuitHeader: SPICEParserStack<String>?

    init(source: String, fileName: String?, initialParameters: [String: String],
         work: (any SPICESourceWorkAccounting)?, storage: SPICEParseStorage? = nil,
         environment: SPICEPreprocessingEnvironment? = nil) throws {
        self.work = work; self.storage = storage; self.inputOwner = storage; self.source = source
        self.fileName = try ConditionalText.copy(fileName ?? "<input>", storage: &self.storage)
        var rootScope = ConditionalMap<String>()
        if let environment {
            for entry in environment.parameters {
                try work?.checkCancellation()
                try rootScope.set(entry.expression, for: entry.name, resources: storage?.resources)
            }
        } else {
            for (name, expression) in initialParameters {
                try rootScope.set(expression, for: name.lowercased(), resources: nil)
            }
        }
        try parameterScopes.append(rootScope, resources: storage?.resources)
        try functionScopes.append(ConditionalMap(), resources: storage?.resources)
    }

    mutating func process() throws -> SPICEConditionalPreprocessor.Result {
        var start = source.startIndex
        var cursor = start
        var lineNumber = 1
        var characters = 0
        while cursor < source.endIndex {
            if source[cursor] == "\n" || source[cursor] == "\r\n" {
                try processSlice(source[start..<cursor], lineNumber: lineNumber)
                lineNumber += 1
                start = source.index(after: cursor)
            }
            cursor = source.index(after: cursor)
            characters += 1
            if characters == 256 { try work?.checkCancellation(); characters = 0 }
        }
        try processSlice(source[start..<cursor], lineNumber: lineNumber)
        try finishSubcircuitHeader()
        if let workFailure { throw workFailure }

        for index in frames.indices.reversed() {
            try work?.checkCancellation()
            let frame = frames[index]
            try diagnostics.append(.error("Unterminated SPICE conditional block", at: frame.openingLocation), resources: storage?.resources)
        }

        guard let resources = storage?.resources else {
            return SPICEConditionalPreprocessor.Result(
                source: try ConditionalText.join(outputLines, separator: "\n", storage: &storage),
                events: try events.export(storage: &storage),
                diagnostics: try diagnostics.export(storage: &storage), storage: nil)
        }
        // Export only actual result backing; helper/evaluator scratch ends with this processor.
        var finalStorage: SPICEParseStorage? = SPICEParseStorage(resources: resources)
        if let inputOwner { try finalStorage!.hold(inputOwner) }
        let finalFile = try ConditionalText.copy(fileName ?? "<input>", storage: &finalStorage)
        let finalSource = try ConditionalText.join(outputLines, separator: "\n", storage: &finalStorage)
        var finalEvents = SPICEParserStack<SPICEPreprocessingEvent>()
        for index in events.indices {
            try resources.checkCancellation()
            let event = events[index]
            let expression: String?
            if let text = event.expression { expression = try ConditionalText.copy(text, storage: &finalStorage) }
            else { expression = nil }
            let location = event.location.map { SourceLocation(file: finalFile, line: $0.line, column: $0.column) }
            try finalEvents.append(SPICEPreprocessingEvent(kind: event.kind, expression: expression,
                active: event.active, location: location, resolved: event.resolved), resources: resources)
        }
        var finalDiagnostics = SPICEParserStack<ParserDiagnostic>()
        for index in diagnostics.indices {
            try resources.checkCancellation()
            let diagnostic = diagnostics[index]
            let message = try ConditionalText.copy(diagnostic.message, storage: &finalStorage)
            let location = diagnostic.location.map { SourceLocation(file: finalFile, line: $0.line, column: $0.column) }
            try finalDiagnostics.append(.error(message, at: location), resources: resources)
        }
        let exportedEvents = try finalEvents.export(storage: &finalStorage)
        let exportedDiagnostics = try finalDiagnostics.export(storage: &finalStorage)
        try resources.checkCancellation()
        return SPICEConditionalPreprocessor.Result(source: finalSource, events: exportedEvents,
            diagnostics: exportedDiagnostics, storage: finalStorage)

    }

    private mutating func processSlice(_ line: Substring, lineNumber: Int) throws {
        try work?.checkCancellation()
        try work?.charge(.retainedElements, units: 1)
        try work?.charge(.projectedBytes, units: UInt64(line.utf8.count))
        try process(line: ConditionalText.copy(line, storage: &storage), lineNumber: lineNumber)
        if let workFailure { throw workFailure }
    }

    private mutating func process(line: String, lineNumber: Int) throws {
        let trimmed = try ConditionalText.trim(line, newlines: false, storage: &storage)
        let isTrivia = try trimmed.hasPrefix("*") || SPICEInlineCommentStripper.strip(from: trimmed, storage: &storage).isEmpty
        if !isTrivia {
            if trimmed.hasPrefix("+"), pendingSubcircuitHeader != nil {
                try pendingSubcircuitHeader?.append(SPICEInlineCommentStripper.strip(from: ConditionalText.copy(trimmed.dropFirst(), storage: &storage), storage: &storage), resources: storage?.resources)
            } else {
                try finishSubcircuitHeader()
            }
        }

        guard let directive = try ConditionalDirective(line: line, fileName: fileName, lineNumber: lineNumber, storage: &storage) else {
            if currentActive {
                try outputLines.append(line, resources: storage?.resources)
                try updateScopeIfNeeded(from: line)
            } else {
                try outputLines.append("", resources: storage?.resources)
            }
            return
        }

        try outputLines.append("", resources: storage?.resources)

        switch directive.kind {
        case .ifStatement:
            try processIf(directive)
        case .elseIf, .elseIfAlias:
            try processElseIf(directive)
        case .elseStatement:
            try processElse(directive)
        case .endIf:
            try processEndIf(directive)
        }
    }

    private mutating func processIf(_ directive: ConditionalDirective) throws {
        let parentActive = currentActive
        var resolved = true
        var branchActive = false
        var branchTaken = false

        if parentActive {
            switch try evaluateCondition(directive.expression, location: directive.location) {
            case .success(let active):
                branchActive = active
                branchTaken = active
            case .failure:
                resolved = false
                branchActive = false
                branchTaken = true
            }
        }

        try frames.append(ConditionalFrame(
            parentActive: parentActive,
            openingLocation: directive.location,
            branchActive: parentActive && branchActive,
            branchTaken: branchTaken,
            hasElse: false
        ), resources: storage?.resources)
        try events.append(SPICEPreprocessingEvent(
            kind: directive.kind,
            expression: directive.expression,
            active: parentActive && branchActive,
            location: directive.location,
            resolved: resolved
        ), resources: storage?.resources)
    }

    private mutating func processElseIf(_ directive: ConditionalDirective) throws {
        guard !frames.isEmpty else {
            try diagnostics.append(.error(try ConditionalText.message(".", directive.kind.rawValue, " without matching .if", storage: &storage), at: directive.location), resources: storage?.resources)
            try events.append(SPICEPreprocessingEvent(
                kind: directive.kind,
                expression: directive.expression,
                active: false,
                location: directive.location
            ), resources: storage?.resources)
            return
        }

        var frame = try frames.removeLast(resources: storage?.resources)!
        if frame.hasElse {
            try diagnostics.append(.error(try ConditionalText.message(".", directive.kind.rawValue, " cannot appear after .else", storage: &storage), at: directive.location), resources: storage?.resources)
            frame.branchActive = false
            try frames.append(frame, resources: storage?.resources)
            try events.append(SPICEPreprocessingEvent(
                kind: directive.kind,
                expression: directive.expression,
                active: false,
                location: directive.location
            ), resources: storage?.resources)
            return
        }

        var resolved = true
        var branchActive = false
        if frame.parentActive && !frame.branchTaken {
            switch try evaluateCondition(directive.expression, location: directive.location) {
            case .success(let active):
                branchActive = active
                if active {
                    frame.branchTaken = true
                }
            case .failure:
                resolved = false
                branchActive = false
                frame.branchTaken = true
            }
        }

        frame.branchActive = frame.parentActive && branchActive
        try frames.append(frame, resources: storage?.resources)
        try events.append(SPICEPreprocessingEvent(
            kind: directive.kind,
            expression: directive.expression,
            active: frame.parentActive && branchActive,
            location: directive.location,
            resolved: resolved
        ), resources: storage?.resources)
    }

    private mutating func processElse(_ directive: ConditionalDirective) throws {
        guard !frames.isEmpty else {
            try diagnostics.append(.error(".else without matching .if", at: directive.location), resources: storage?.resources)
            try events.append(SPICEPreprocessingEvent(
                kind: directive.kind,
                expression: nil,
                active: false,
                location: directive.location
            ), resources: storage?.resources)
            return
        }

        var frame = try frames.removeLast(resources: storage?.resources)!
        if frame.hasElse {
            try diagnostics.append(.error("Duplicate .else in SPICE conditional block", at: directive.location), resources: storage?.resources)
            frame.branchActive = false
        } else {
            frame.hasElse = true
            frame.branchActive = frame.parentActive && !frame.branchTaken
            frame.branchTaken = true
        }
        let active = frame.branchActive
        try frames.append(frame, resources: storage?.resources)
        try events.append(SPICEPreprocessingEvent(
            kind: directive.kind,
            expression: nil,
            active: active,
            location: directive.location
        ), resources: storage?.resources)
    }

    private mutating func processEndIf(_ directive: ConditionalDirective) throws {
        guard let frame = try frames.removeLast(resources: storage?.resources) else {
            try diagnostics.append(.error(".endif without matching .if", at: directive.location), resources: storage?.resources)
            try events.append(SPICEPreprocessingEvent(
                kind: directive.kind,
                expression: nil,
                active: false,
                location: directive.location
            ), resources: storage?.resources)
            return
        }

        try events.append(SPICEPreprocessingEvent(
            kind: directive.kind,
            expression: nil,
            active: frame.branchActive,
            location: directive.location
        ), resources: storage?.resources)
    }

    private mutating func updateScopeIfNeeded(from line: String) throws {
        guard let directive = try ParsedLineDirective(line: line, storage: &storage) else { return }
        switch directive.keyword {
        case "subckt":
            try parameterScopes.append(ConditionalMap(), resources: storage?.resources)
            try functionScopes.append(ConditionalMap(), resources: storage?.resources)
            var header = SPICEParserStack<String>()
            try header.append(SPICEInlineCommentStripper.strip(from: directive.body, storage: &storage), resources: storage?.resources)
            pendingSubcircuitHeader = header
        case "ends":
            if parameterScopes.count > 1 { _ = try parameterScopes.removeLast(resources: storage?.resources) }
            if functionScopes.count > 1 { _ = try functionScopes.removeLast(resources: storage?.resources) }
        case "param":
            let assignments = try ParameterAssignmentParser.parse(directive.body, storage: &storage)
            var scope = parameterScopes[parameterScopes.count - 1]
            for index in assignments.indices {
                try work?.checkCancellation()
                let assignment = assignments[index]
                let name = try ConditionalText.lower(assignment.name, storage: &storage)
                try scope.set(assignment.expression, for: name, resources: storage?.resources)
            }
            try parameterScopes.replace(at: parameterScopes.count - 1, with: scope, resources: storage?.resources)
        case "func", "function":
            guard let definition = try FunctionDefinitionParser.parse(directive.body, storage: &storage) else { return }
            var scope = functionScopes[functionScopes.count - 1]
            try scope.set(definition, for: definition.name, resources: storage?.resources)
            try functionScopes.replace(at: functionScopes.count - 1, with: scope, resources: storage?.resources)
        default: break
        }
    }

    private mutating func subcircuitParameters(from body: String) throws -> ConditionalMap<String> {
        var lexer = SPICELexer(source: body)
        let tokens: [SPICEToken.Located]
        var tokenOwner: SPICEParseStorage?
        if let resources = storage?.resources {
            let owned = try lexer.tokenizeOwned(resources: resources)
            tokens = owned.tokens; tokenOwner = owned.storage
        } else { tokens = try lexer.tokenizeChecked(work: work) }
        defer { withExtendedLifetime(tokenOwner) {} }
        try work?.charge(.retainedElements, units: UInt64(tokens.count))
        // The first field names the subcircuit, even when it is named "params".
        for index in tokens.indices.dropFirst() {
            try work?.checkCancellation()
            let token = tokens[index]
            guard case .identifier(let name) = token.token else { continue }
            let normalized = try ConditionalText.lower(name, storage: &storage)
            let isMarker = normalized == "params" || normalized == "params:"
            let isAssignment = index + 1 < tokens.count && tokens[index + 1].token == .equals
            guard isMarker || isAssignment else { continue }
            var start = body.startIndex
            for _ in 0..<(token.location.column - 1) {
                try ConditionalText.step(storage)
                start = body.index(after: start)
            }
            var parameterText = try ConditionalText.copy(body[start...], storage: &storage)
            if isMarker {
                var parameterStart = parameterText.startIndex
                for _ in name {
                    try ConditionalText.step(storage)
                    parameterStart = parameterText.index(after: parameterStart)
                }
                parameterText = try ConditionalText.copy(parameterText[parameterStart...], storage: &storage)
                parameterText = try ConditionalText.trim(parameterText, newlines: false, storage: &storage)
                if parameterText.hasPrefix(":") { parameterText = try ConditionalText.copy(parameterText.dropFirst(), storage: &storage) }
            }
            let assignments = try ParameterAssignmentParser.parse(parameterText, storage: &storage)
            var result = ConditionalMap<String>()
            for index in assignments.indices {
                try work?.checkCancellation()
                let assignment = assignments[index]
                let name = try ConditionalText.lower(assignment.name, storage: &storage)
                try result.set(assignment.expression, for: name, resources: storage?.resources)
            }
            return result
        }
        return ConditionalMap()
    }

    private mutating func finishSubcircuitHeader() throws {
        guard let header = pendingSubcircuitHeader else { return }
        pendingSubcircuitHeader = nil
        let body = try ConditionalText.join(header, separator: " ", storage: &storage)
        let parameters = try subcircuitParameters(from: body)
        try parameterScopes.replace(at: parameterScopes.count - 1, with: parameters, resources: storage?.resources)
    }

    private mutating func evaluateCondition(
        _ expression: String?,
        location: SourceLocation
    ) throws -> Result<Bool, SPICEConditionalExpressionError> {
        guard let expression, !(try ConditionalText.trim(expression, newlines: true, storage: &storage)).isEmpty else {
            let error = SPICEConditionalExpressionError(message: "Missing condition expression")
            try diagnostics.append(.error(try ConditionalText.message("Invalid SPICE conditional expression: ", error.message, storage: &storage), at: location), resources: storage?.resources)
            return .failure(error)
        }

        do {
            var evaluationStorage = storage.map { SPICEParseStorage(resources: $0.resources) }
            let parsedExpression = try ConditionalText.parseExpression(expression, fileName: location.file, storage: &evaluationStorage, work: work)
            var evaluator = SPICEConditionalExpressionEvaluator(
                parameters: try mergedParameterExpressions(),
                parameterValues: ConditionalMap(),
                functions: try mergedFunctionDefinitions(),
                resolvingParameters: ConditionalMap(),
                resolvingFunctions: ConditionalMap(),
                work: work, storage: evaluationStorage
            )
            let value = try evaluator.evaluate(parsedExpression)
            return .success(value != 0)
        } catch let diagnostic as ParserDiagnostic {
            let error = SPICEConditionalExpressionError(message: diagnostic.message)
            try diagnostics.append(.error(try ConditionalText.message("Invalid SPICE conditional expression: ", error.message, storage: &storage), at: location), resources: storage?.resources)
            return .failure(error)
        } catch let error as SPICEConditionalExpressionError {
            try diagnostics.append(.error(try ConditionalText.message("Invalid SPICE conditional expression: ", error.message, storage: &storage), at: location), resources: storage?.resources)
            return .failure(error)
        } catch {
            if storage != nil { throw error }
            if work != nil { workFailure = error }
            let wrapped = SPICEConditionalExpressionError(message: "\(error)")
            try diagnostics.append(.error(try ConditionalText.message("Invalid SPICE conditional expression: ", wrapped.message, storage: &storage), at: location), resources: storage?.resources)
            return .failure(wrapped)
        }
    }

    private var currentActive: Bool {
        frames.last?.branchActive ?? true
    }

    private func mergedParameterExpressions() throws -> ConditionalMap<String> {
        var result = ConditionalMap<String>()
        for index in parameterScopes.indices {
            try work?.checkCancellation()
            try parameterScopes[index].forEach(resources: storage?.resources) { name, expression in
                try result.set(expression, for: name, resources: storage?.resources)
            }
        }
        return result
    }

    private func mergedFunctionDefinitions() throws -> ConditionalMap<ConditionalFunctionDefinition> {
        var result = ConditionalMap<ConditionalFunctionDefinition>()
        for index in functionScopes.indices {
            try work?.checkCancellation()
            try functionScopes[index].forEach(resources: storage?.resources) { name, definition in
                try result.set(definition, for: name, resources: storage?.resources)
            }
        }
        return result
    }

}

private struct ConditionalDirective {
    let kind: SPICEConditionalDirectiveKind
    let expression: String?
    let location: SourceLocation

    init?(line: String, fileName: String?, lineNumber: Int, storage: inout SPICEParseStorage?) throws {
        guard let parsed = try ParsedLineDirective(line: line, storage: &storage),
              let kind = SPICEConditionalDirectiveKind(rawValue: parsed.keyword) else {
            return nil
        }
        self.kind = kind
        let uncommentedBody = try SPICEInlineCommentStripper.strip(from: parsed.body, storage: &storage)
        let trimmedBody = try ConditionalText.trim(uncommentedBody, newlines: true, storage: &storage)
        expression = trimmedBody.isEmpty ? nil : trimmedBody
        location = SourceLocation(file: fileName ?? "<input>", line: lineNumber, column: parsed.directiveColumn)
    }
}

private struct ParsedLineDirective {
    let keyword: String
    let body: String
    let directiveColumn: Int

    init?(line: String, storage: inout SPICEParseStorage?) throws {
        var index = line.startIndex
        var directiveColumn = 1
        while index < line.endIndex, line[index].isWhitespace {
            try ConditionalText.step(storage)
            index = line.index(after: index)
            directiveColumn += 1
        }
        guard index < line.endIndex, line[index] == "." else {
            return nil
        }

        index = line.index(after: index)
        let keywordStart = index
        while index < line.endIndex, Self.isDirectiveCharacter(line[index]) {
            try ConditionalText.step(storage)
            index = line.index(after: index)
        }
        guard keywordStart < index else {
            return nil
        }

        keyword = try ConditionalText.lower(ConditionalText.copy(line[keywordStart..<index], storage: &storage), storage: &storage)
        let bodyStart = index
        body = try ConditionalText.copy(line[bodyStart...], storage: &storage)
        self.directiveColumn = directiveColumn
    }

    private static func isDirectiveCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}

private struct ParameterAssignment: Sendable {
    let name: String
    let expression: String
}

private struct ConditionalFunctionDefinition: Sendable, Hashable {
    let name: String
    let parameters: [String]
    let body: String
}

private struct FunctionDefinitionParser {

    static func parse(_ body: String, storage: inout SPICEParseStorage?) throws -> ConditionalFunctionDefinition? {
        let text = try SPICEInlineCommentStripper.strip(from: body, storage: &storage)
        var index = text.startIndex
        try skipWhitespace(in: text, index: &index, storage: &storage)

        guard let name = try readIdentifier(in: text, index: &index, storage: &storage) else {
            return nil
        }
        try skipWhitespace(in: text, index: &index, storage: &storage)
        guard index < text.endIndex, text[index] == "(" else {
            return nil
        }
        index = text.index(after: index)

        var parameters = SPICEParserStack<String>()
        try skipWhitespace(in: text, index: &index, storage: &storage)
        if index < text.endIndex, text[index] != ")" {
            while true {
                try ConditionalText.step(storage)
                try skipWhitespace(in: text, index: &index, storage: &storage)
                guard let parameter = try readIdentifier(in: text, index: &index, storage: &storage) else {
                    return nil
                }
                try parameters.append(ConditionalText.lower(parameter, storage: &storage), resources: storage?.resources)
                try skipWhitespace(in: text, index: &index, storage: &storage)
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
        try skipWhitespace(in: text, index: &index, storage: &storage)
        if index < text.endIndex, text[index] == "=" {
            index = text.index(after: index)
            try skipWhitespace(in: text, index: &index, storage: &storage)
        }

        let bodyText = try ConditionalText.trim(ConditionalText.copy(text[index...], storage: &storage), newlines: true, storage: &storage)
        guard !bodyText.isEmpty else {
            return nil
        }

        return ConditionalFunctionDefinition(
            name: try ConditionalText.lower(name, storage: &storage),
            parameters: try parameters.export(storage: &storage),
            body: try ParameterAssignmentParser.stripOuterBraces(bodyText, storage: &storage)
        )
    }

    private static func readIdentifier(in text: String, index: inout String.Index, storage: inout SPICEParseStorage?) throws -> String? {
        guard index < text.endIndex, isIdentifierStart(text[index]) else {
            return nil
        }
        let start = index
        index = text.index(after: index)
        while index < text.endIndex, isIdentifierCharacter(text[index]) {
            try ConditionalText.step(storage)
            index = text.index(after: index)
        }
        return try ConditionalText.copy(text[start..<index], storage: &storage)
    }

    private static func skipWhitespace(in text: String, index: inout String.Index, storage: inout SPICEParseStorage?) throws {
        while index < text.endIndex, text[index].isWhitespace {
            try ConditionalText.step(storage)
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

    static func parse(_ body: String, storage: inout SPICEParseStorage?) throws -> SPICEParserStack<ParameterAssignment> {
        let text = try SPICEInlineCommentStripper.strip(from: body, storage: &storage)
        var assignments = SPICEParserStack<ParameterAssignment>()
        var index = text.startIndex

        while index < text.endIndex {
            try ConditionalText.step(storage)
            try skipWhitespace(in: text, index: &index, storage: &storage)
            guard let name = try readIdentifier(in: text, index: &index, storage: &storage) else {
                break
            }
            try skipWhitespace(in: text, index: &index, storage: &storage)
            guard index < text.endIndex, text[index] == "=" else {
                continue
            }
            index = text.index(after: index)
            try skipWhitespace(in: text, index: &index, storage: &storage)

            let valueStart = index
            try readValue(in: text, index: &index, storage: &storage)
            let value = try ConditionalText.trim(ConditionalText.copy(text[valueStart..<index], storage: &storage), newlines: true, storage: &storage)
            if !value.isEmpty {
                try assignments.append(ParameterAssignment(name: name, expression: stripOuterBraces(value, storage: &storage)), resources: storage?.resources)
            }
        }

        return assignments
    }

    private static func readValue(in text: String, index: inout String.Index, storage: inout SPICEParseStorage?) throws {
        var braceDepth = 0
        var parenDepth = 0
        var quote: Character?

        while index < text.endIndex {
            try ConditionalText.step(storage)
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
                try skipWhitespace(in: text, index: &probe, storage: &storage)
                if try startsAssignment(in: text, at: probe, storage: &storage) {
                    index = whitespaceStart
                    return
                }
                index = probe
                continue
            }
            index = text.index(after: index)
        }
    }

    private static func startsAssignment(in text: String, at index: String.Index, storage: inout SPICEParseStorage?) throws -> Bool {
        var probe = index
        guard try readIdentifier(in: text, index: &probe, storage: &storage) != nil else {
            return false
        }
        try skipWhitespace(in: text, index: &probe, storage: &storage)
        return probe < text.endIndex && text[probe] == "="
    }

    private static func readIdentifier(in text: String, index: inout String.Index, storage: inout SPICEParseStorage?) throws -> String? {
        guard index < text.endIndex, isIdentifierStart(text[index]) else {
            return nil
        }
        let start = index
        index = text.index(after: index)
        while index < text.endIndex, isIdentifierCharacter(text[index]) {
            try ConditionalText.step(storage)
            index = text.index(after: index)
        }
        return try ConditionalText.copy(text[start..<index], storage: &storage)
    }

    static func stripOuterBraces(_ value: String, storage: inout SPICEParseStorage?) throws -> String {
        let trimmed = try ConditionalText.trim(value, newlines: true, storage: &storage)
        guard trimmed.first == "{", trimmed.last == "}" else {
            return trimmed
        }
        return try ConditionalText.trim(ConditionalText.copy(trimmed.dropFirst().dropLast(), storage: &storage), newlines: true, storage: &storage)
    }

    private static func skipWhitespace(in text: String, index: inout String.Index, storage: inout SPICEParseStorage?) throws {
        while index < text.endIndex, text[index].isWhitespace {
            try ConditionalText.step(storage)
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
    static func strip(from text: String, storage: inout SPICEParseStorage?) throws -> String {
        var braceDepth = 0, parenDepth = 0
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            try ConditionalText.step(storage)
            let character = text[index]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "'" || character == "\"" { quote = character }
            else if character == "{" { braceDepth += 1 }
            else if character == "}", braceDepth > 0 { braceDepth -= 1 }
            else if character == "(" { parenDepth += 1 }
            else if character == ")", parenDepth > 0 { parenDepth -= 1 }
            else if (character == "$" || character == ";"), braceDepth == 0, parenDepth == 0 { break }
            index = text.index(after: index)
        }
        return try ConditionalText.copy(text[..<index], storage: &storage)
    }
}

private struct SPICEConditionalExpressionError: Error, Sendable {
    let message: String
    var storage: SPICEParseStorage? = nil
}

private struct SPICEConditionalExpressionEvaluator {

    private let work: (any SPICESourceWorkAccounting)?
    private let parameters: ConditionalMap<String>
    private let parameterValues: ConditionalMap<Double>
    private let functions: ConditionalMap<ConditionalFunctionDefinition>
    private var resolvingParameters: ConditionalMap<Bool>
    private var resolvingFunctions: ConditionalMap<Bool>
    private var storage: SPICEParseStorage?

    init(
        parameters: ConditionalMap<String>,
        parameterValues: ConditionalMap<Double>,
        functions: ConditionalMap<ConditionalFunctionDefinition>,
        resolvingParameters: ConditionalMap<Bool>,
        resolvingFunctions: ConditionalMap<Bool>,
        work: (any SPICESourceWorkAccounting)? = nil, storage: SPICEParseStorage? = nil
    ) {
        self.work = work; self.storage = storage
        self.parameters = parameters
        self.parameterValues = parameterValues
        self.functions = functions
        self.resolvingParameters = resolvingParameters
        self.resolvingFunctions = resolvingFunctions
    }

    mutating func evaluate(_ expression: ParsedExpression) throws -> Double {
        try work?.checkCancellation()
        try work?.charge(.conditionalEvaluations, units: 1)
        switch expression {
        case .literal(let value):
            return value
        case .identifier(let name):
            return try resolveIdentifier(ConditionalText.lower(name, storage: &storage))
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
            var values = SPICEParserStack<Double>()
            for argument in arguments { try values.append(evaluate(argument), resources: storage?.resources) }
            return try evaluateFunction(name: ConditionalText.lower(name, storage: &storage), arguments: values)
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

        if let parameterValue = try parameterValues.value(for: name, resources: storage?.resources) {
            return parameterValue
        }

        guard let parameterExpression = try parameters.value(for: name, resources: storage?.resources) else {
            throw SPICEConditionalExpressionError(message: try ConditionalText.message("Unknown conditional parameter '", name, "'", storage: &storage), storage: storage)
        }
        guard try resolvingParameters.value(for: name, resources: storage?.resources) == nil else {
            throw SPICEConditionalExpressionError(message: try ConditionalText.message("Recursive conditional parameter '", name, "'", storage: &storage), storage: storage)
        }

        try resolvingParameters.set(true, for: name, resources: storage?.resources)
        let expression: ParsedExpression
        do {
            expression = try ConditionalText.parseExpression(ParameterAssignmentParser.stripOuterBraces(parameterExpression, storage: &storage), storage: &storage, work: work)
        } catch let diagnostic as ParserDiagnostic {
            try resolvingParameters.remove(name, resources: storage?.resources)
            throw SPICEConditionalExpressionError(message: diagnostic.message)
        }
        var evaluator = SPICEConditionalExpressionEvaluator(
            parameters: parameters,
            parameterValues: parameterValues,
            functions: functions,
            resolvingParameters: resolvingParameters,
            resolvingFunctions: resolvingFunctions,
            work: work, storage: storage
        )
        let value = try evaluator.evaluate(expression)
        try resolvingParameters.remove(name, resources: storage?.resources)
        return value
    }

    private mutating func evaluateFunction(name: String, arguments: SPICEParserStack<Double>) throws -> Double {
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
            return try extremum(arguments, minimum: true)
        case "max":
            try requireMinimumArgumentCount(2, for: name, arguments: arguments)
            return try extremum(arguments, minimum: false)
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

    private mutating func evaluateUserFunction(name: String, arguments: SPICEParserStack<Double>) throws -> Double {
        guard let function = try functions.value(for: name, resources: storage?.resources) else {
            throw SPICEConditionalExpressionError(message: try ConditionalText.message("Unsupported conditional function '", name, "'", storage: &storage), storage: storage)
        }
        guard function.parameters.count == arguments.count else {
            throw SPICEConditionalExpressionError(
                message: try argumentCountMessage(name: name, count: function.parameters.count, minimum: false), storage: storage
            )
        }
        guard try resolvingFunctions.value(for: name, resources: storage?.resources) == nil else {
            throw SPICEConditionalExpressionError(message: try ConditionalText.message("Recursive conditional function '", name, "'", storage: &storage), storage: storage)
        }

        var scopedParameterValues = parameterValues
        for index in function.parameters.indices {
            try work?.checkCancellation()
            try scopedParameterValues.set(arguments[index], for: function.parameters[index], resources: storage?.resources)
        }
        var nextResolvingFunctions = resolvingFunctions
        try nextResolvingFunctions.set(true, for: name, resources: storage?.resources)
        let expression: ParsedExpression
        do {
            expression = try ConditionalText.parseExpression(function.body, storage: &storage, work: work)
        } catch let diagnostic as ParserDiagnostic {
            throw SPICEConditionalExpressionError(message: diagnostic.message)
        }
        var evaluator = SPICEConditionalExpressionEvaluator(
            parameters: parameters,
            parameterValues: scopedParameterValues,
            functions: functions,
            resolvingParameters: resolvingParameters,
            resolvingFunctions: nextResolvingFunctions,
            work: work, storage: storage
        )
        return try evaluator.evaluate(expression)
    }

    private mutating func requireArgumentCount(
        _ count: Int,
        for name: String,
        arguments: SPICEParserStack<Double>
    ) throws {
        guard arguments.count == count else {
            throw SPICEConditionalExpressionError(
                message: try argumentCountMessage(name: name, count: count, minimum: false), storage: storage
            )
        }
    }

    private mutating func requireMinimumArgumentCount(
        _ count: Int,
        for name: String,
        arguments: SPICEParserStack<Double>
    ) throws {
        guard arguments.count >= count else {
            throw SPICEConditionalExpressionError(
                message: try argumentCountMessage(name: name, count: count, minimum: true), storage: storage
            )
        }
    }

    private func extremum(_ arguments: SPICEParserStack<Double>, minimum: Bool) throws -> Double {
        var value = arguments[0]
        for index in arguments.indices.dropFirst() {
            try work?.checkCancellation()
            try storage?.resources.charge(.conditionalEvaluations, units: 1)
            if minimum ? arguments[index] < value : arguments[index] > value { value = arguments[index] }
        }
        return value
    }

    private mutating func argumentCountMessage(name: String, count: Int, minimum: Bool) throws -> String {
        guard storage != nil else {
            return minimum ? "Function \(name) requires at least \(count) argument(s)" : "Function \(name) requires \(count) argument(s)"
        }
        let countText = try ConditionalText.integer(count, storage: &storage)
        let detail = try ConditionalText.message(minimum ? " requires at least " : " requires ", countText, " argument(s)", storage: &storage)
        return try ConditionalText.message("Function ", name, detail, storage: &storage)
    }

    private func isTrue(_ value: Double) -> Bool {
        value != 0
    }
}

/// Uses the common map hook on the bounded branch; standalone dictionaries preserve legacy behavior.
private struct ConditionalMap<Value: Sendable>: Sendable {
    private var ordinary: [String: Value] = [:]
    private var owned = SPICEAccountedMap<Value>()
    mutating func set(_ value: Value, for key: String,
                      resources: (any SPICESourceResourceAccounting)?) throws {
        if let resources { try owned.set(value, for: key, resources: resources) }
        else { ordinary[key] = value }
    }
    func value(for key: String, resources: (any SPICESourceResourceAccounting)?) throws -> Value? {
        if let resources { return try owned.value(for: key, resources: resources) }
        return ordinary[key]
    }
    mutating func remove(_ key: String, resources: (any SPICESourceResourceAccounting)?) throws {
        if let resources { try owned.removeValue(for: key, resources: resources) }
        else { ordinary.removeValue(forKey: key) }
    }
    func forEach(resources: (any SPICESourceResourceAccounting)?, _ body: (String, Value) throws -> Void) throws {
        if let resources { try owned.forEach(resources: resources, body) }
        else { for (key, value) in ordinary { try body(key, value) } }
    }
}

/// Shared grammar transformations, with concrete storage and cooperative ASCII operations when bounded.
private enum ConditionalText {
    static func step(_ storage: SPICEParseStorage?) throws {
        try storage?.resources.checkCancellation()
        try storage?.resources.charge(.lexicalBytes, units: 1)
    }
    static func checkASCII<S: StringProtocol>(_ text: S, storage: SPICEParseStorage?) throws {
        guard let resources = storage?.resources else { return }
        try resources.charge(.lexicalBytes, units: UInt64(text.utf8.count))
        var index = 0
        for byte in text.utf8 {
            if index.isMultiple(of: 256) { try resources.checkCancellation() }
            guard byte < 128 else {
                throw SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode conditional processing")
            }
            index += 1
        }
        try resources.checkCancellation()
    }
    static func copy<S: StringProtocol>(_ text: S, storage: inout SPICEParseStorage?) throws -> String {
        guard let resources = storage?.resources else { return String(text) }
        try checkASCII(text, storage: storage)
        let count = text.utf8.count
        let reservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(count))
        try resources.charge(.projectedBytes, units: UInt64(count))
        var output = ""
        output.reserveCapacity(count)
        var index = 0
        for character in text {
            if index.isMultiple(of: 256) { try resources.checkCancellation() }
            output.append(character); index += 1
        }
        try resources.checkCancellation()
        try storage!.retain(output, reservation: reservation)
        return output
    }
    static func trim(_ text: String, newlines: Bool, storage: inout SPICEParseStorage?) throws -> String {
        guard storage != nil else {
            return text.trimmingCharacters(in: newlines ? .whitespacesAndNewlines : .whitespaces)
        }
        try checkASCII(text, storage: storage)
        func whitespace(_ character: Character) -> Bool {
            character == " " || character == "\t" || character == "\u{000B}" || character == "\u{000C}" ||
                (newlines && (character == "\n" || character == "\r" || character == "\r\n"))
        }
        var start = text.startIndex, end = text.endIndex
        while start < end, whitespace(text[start]) { try step(storage); start = text.index(after: start) }
        while start < end {
            try step(storage)
            let previous = text.index(before: end)
            guard whitespace(text[previous]) else { break }
            end = previous
        }
        return try copy(text[start..<end], storage: &storage)
    }
    static func lower(_ text: String, storage: inout SPICEParseStorage?) throws -> String {
        guard let resources = storage?.resources else { return text.lowercased() }
        try checkASCII(text, storage: storage)
        let count = text.utf8.count
        let reservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(count))
        try resources.charge(.projectedBytes, units: UInt64(count))
        var output = ""
        output.reserveCapacity(count)
        var index = 0
        for byte in text.utf8 {
            if index.isMultiple(of: 256) { try resources.checkCancellation() }
            output.unicodeScalars.append(UnicodeScalar(byte >= 65 && byte <= 90 ? byte + 32 : byte))
            index += 1
        }
        try storage!.retain(output, reservation: reservation)
        return output
    }
    static func join(_ values: SPICEParserStack<String>, separator: String,
                     storage: inout SPICEParseStorage?) throws -> String {
        guard let resources = storage?.resources else {
            var result = ""
            for index in values.indices {
                if index > 0 { result.append(separator) }
                result.append(values[index])
            }
            return result
        }
        var byteCount = 0
        for index in values.indices {
            try resources.checkCancellation()
            let (next, overflow) = byteCount.addingReportingOverflow(values[index].utf8.count)
            guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
            byteCount = next
            if index > 0 {
                let (next, overflow) = byteCount.addingReportingOverflow(separator.utf8.count)
                guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
                byteCount = next
            }
        }
        let reservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(byteCount))
        try resources.charge(.projectedBytes, units: UInt64(byteCount))
        var output = ""
        output.reserveCapacity(byteCount)
        for index in values.indices {
            try resources.checkCancellation()
            if index > 0 { output.append(separator) }
            var position = 0
            for character in values[index] {
                if position.isMultiple(of: 256) { try resources.checkCancellation() }
                output.append(character); position += 1
            }
        }
        try storage!.retain(output, reservation: reservation)
        return output
    }
    static func message(_ prefix: String, _ value: String, _ suffix: String = "",
                        storage: inout SPICEParseStorage?) throws -> String {
        var pieces = SPICEParserStack<String>()
        try pieces.append(prefix, resources: storage?.resources)
        try pieces.append(value, resources: storage?.resources)
        try pieces.append(suffix, resources: storage?.resources)
        return try join(pieces, separator: "", storage: &storage)
    }
    static func integer(_ value: Int, storage: inout SPICEParseStorage?) throws -> String {
        guard let resources = storage?.resources else { return String(value) }
        var magnitude = value.magnitude
        var capacity = value < 0 ? 1 : 0
        repeat {
            try resources.checkCancellation()
            capacity += 1
            magnitude /= 10
        } while magnitude != 0
        let reservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(capacity))
        let text = String(value)
        try resources.charge(.projectedBytes, units: UInt64(capacity))
        try storage!.retain(text, reservation: reservation)
        return text
    }
    static func parseExpression(_ source: String, fileName: String? = nil,
                                storage: inout SPICEParseStorage?, work: (any SPICESourceWorkAccounting)?) throws -> ParsedExpression {
        guard storage != nil else { return try SPICEExpressionParser().parse(source, fileName: fileName, work: work) }
        let result = try SPICEExpressionParser().parse(source, fileName: fileName, storage: &storage!)
        return result
    }
}

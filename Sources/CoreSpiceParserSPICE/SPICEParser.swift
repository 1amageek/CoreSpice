import CoreSpiceParsedIR
import CoreSpiceParser

/// A parser for SPICE netlist files.
///
/// Implements the `NetlistParser` protocol to parse standard SPICE
/// and HSPICE netlist formats.
public struct SPICEParser: NetlistParser {

    public let formatIdentifier = "spice"
    public let fileExtensions = [".sp", ".cir", ".spice", ".net", ".spi"]
    public let formatName = "SPICE Netlist"

    public init() {}

    public func parse(
        source: String,
        fileName: String?,
        configuration: ParserConfiguration,
        fileResolver: any FileResolver
    ) async -> ParseResult {
        var parser = SPICEParserImpl(
            source: source,
            fileName: fileName,
            configuration: configuration,
            fileResolver: fileResolver
        )
        return await parser.parse()
    }

    public func canParse(source: String) -> Bool {
        let lines = source.split(separator: "\n", maxSplits: 10, omittingEmptySubsequences: false)

        // Check for SPICE-like content
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()

            // First line is typically title (skip)
            if index == 0 { continue }

            // Look for SPICE directives
            if trimmed.hasPrefix(".") {
                let directive = trimmed.dropFirst().split(separator: " ").first ?? ""
                let spiceDirectives = ["subckt", "model", "param", "include", "lib", "end", "ends",
                                       "tran", "ac", "dc", "op", "print", "plot", "option", "options",
                                       "ic", "nodeset", "global", "temp"]
                if spiceDirectives.contains(String(directive)) {
                    return true
                }
            }

            // Look for component lines (R1, C1, M1, etc.)
            if let first = trimmed.first, "rcldqmjvixef".contains(first.lowercased()) {
                return true
            }

            // Look for * comments
            if trimmed.hasPrefix("*") {
                continue
            }
        }

        return false
    }
}

/// Internal implementation of the SPICE parser.
private struct SPICEParserImpl {

    private let source: String
    private let fileName: String?
    private let configuration: ParserConfiguration
    private let fileResolver: any FileResolver
    private let includeDepth: Int

    private var tokens: [SPICEToken.Located] = []
    private var current = 0
    private var diagnostics: [ParserDiagnostic] = []

    // Parse state
    private var components: [ParsedComponent] = []
    private var models: [ParsedModel] = []
    private var subcircuits: [ParsedSubcircuit] = []
    private var analyses: [ParsedAnalysisCommand] = []
    private var controls: [ParsedControlStatement] = []
    private var parameters: [String: ParsedExpression] = [:]
    private var initialConditions: [String: ParsedParameterValue] = [:]
    private var nodeSets: [String: ParsedParameterValue] = [:]
    private var globalNodes: [String] = []
    private var title: String?

    init(
        source: String,
        fileName: String?,
        configuration: ParserConfiguration,
        fileResolver: any FileResolver,
        includeDepth: Int = 0
    ) {
        self.source = source
        self.fileName = fileName
        self.configuration = configuration
        self.fileResolver = fileResolver
        self.includeDepth = includeDepth
    }

    mutating func parse() async -> ParseResult {
        // Tokenize
        var lexer = SPICELexer(source: source, fileName: fileName, configuration: configuration)
        tokens = lexer.tokenize()

        // Parse title (first line)
        parseTitle()

        // Parse statements
        while !isAtEnd {
            do {
                try await parseStatement()
            } catch {
                if let diag = error as? ParserDiagnostic {
                    diagnostics.append(diag)
                } else {
                    diagnostics.append(.error("\(error)", at: currentLocation))
                }
                synchronize()
            }
        }

        let netlist = ParsedNetlist(
            title: title,
            components: components,
            models: models,
            subcircuits: subcircuits,
            analyses: analyses,
            controls: controls,
            parameters: parameters,
            initialConditions: initialConditions,
            nodeSets: nodeSets,
            globalNodes: globalNodes
        )

        if diagnostics.contains(where: { $0.severity == .error }) {
            return ParseResult(netlist: netlist, diagnostics: diagnostics)
        }

        return ParseResult(netlist: netlist, diagnostics: diagnostics)
    }

    // MARK: - Parsing Methods

    private mutating func parseTitle() {
        // In SPICE, the very first line is always the title.
        // If it starts with '*' it was lexed as a .comment token.
        switch currentToken {
        case .comment(let text):
            // Strip leading "* " from comment text
            let stripped = text.drop(while: { $0 == "*" || $0 == " " })
            title = String(stripped)
            advance()
        case .identifier(let text):
            var titleText = text
            advance()
            while !isAtEnd && !isNewline {
                if case .identifier(let more) = currentToken {
                    titleText += " " + more
                } else if case .number(let n) = currentToken {
                    titleText += " " + String(n)
                }
                advance()
            }
            title = titleText
        default:
            break
        }
        // Skip trailing newlines/comments after the title line
        skipNewlinesAndComments()
    }

    private mutating func parseStatement() async throws {
        skipNewlinesAndComments()
        guard !isAtEnd else { return }

        switch currentToken {
        case .directive(let name):
            try await parseDirective(name)

        case .identifier(let name):
            try parseComponent(name: name)

        case .comment:
            advance()

        case .newline, .continuation:
            advance()

        default:
            advance()
        }
    }

    private mutating func parseDirective(_ name: String) async throws {
        let loc = currentLocation
        advance() // skip directive

        switch name {
        case "subckt":
            try await parseSubcircuit(location: loc)
        case "model":
            try parseModel(location: loc)
        case "param":
            try parseParam(location: loc)
        case "include":
            try await parseInclude(location: loc)
        case "lib":
            try await parseLib(location: loc)
        case "end":
            skipToEndOfLine()
        case "ends":
            skipToEndOfLine()
        case "tran":
            try parseTransientAnalysis(location: loc)
        case "ac":
            try parseACAnalysis(location: loc)
        case "dc":
            try parseDCAnalysis(location: loc)
        case "op":
            analyses.append(.op)
            skipToEndOfLine()
        case "temp":
            try parseTemp(location: loc)
        case "ic":
            try parseIC(location: loc)
        case "nodeset":
            try parseNodeset(location: loc)
        case "global":
            try parseGlobal(location: loc)
        case "option", "options":
            try parseOption(location: loc)
        case "print":
            try parsePrint(location: loc)
        case "plot":
            try parsePlot(location: loc)
        case "save":
            try parseSave(location: loc)
        case "noise":
            try parseNoiseAnalysis(location: loc)
        case "tf":
            try parseTransferFunctionAnalysis(location: loc)
        case "sens":
            try parseSensitivityAnalysis(location: loc)
        case "four", "fourier":
            try parseFourierAnalysis(location: loc)
        case "pz":
            try parsePoleZeroAnalysis(location: loc)
        case "mc", "montecarlo":
            try parseMonteCarloAnalysis(location: loc)
        case "meas", "measure":
            try parseMeasure(location: loc)
        default:
            // Unknown directive - skip to end of line
            diagnostics.append(.warning("Unknown directive: .\(name)", at: loc))
            skipToEndOfLine()
        }
    }

    private mutating func parseComponent(name: String) throws {
        let loc = currentLocation
        advance() // skip name

        guard let firstChar = name.first else {
            throw ParserDiagnostic.error("Empty component name", at: loc)
        }

        guard let type = ComponentType(prefix: firstChar) else {
            throw ParserDiagnostic.error("Unknown component type: \(firstChar)", at: loc)
        }

        var nodes: [ParsedNodeRef] = []
        var modelName: String?
        var params: [String: ParsedParameterValue] = [:]

        // Parse nodes
        let nodeCount = type.standardNodeCount ?? 2

        // For subcircuit instances, collect all non-parameter tokens as nodes
        if type == .subcircuitInstance {
            // Nodes until we hit the subcircuit name (last identifier before params)
            var identifiers: [String] = []
            while !isAtEnd && !isNewline && !isParameterStart {
                if case .identifier(let id) = currentToken {
                    identifiers.append(id)
                    advance()
                } else {
                    break
                }
            }
            // Last identifier is the subcircuit name
            if let subcktName = identifiers.popLast() {
                modelName = subcktName
            }
            nodes = identifiers.map { ParsedNodeRef(name: $0, location: loc) }
        } else {
            // Parse fixed number of nodes
            for _ in 0..<nodeCount {
                if case .identifier(let nodeName) = currentToken {
                    nodes.append(ParsedNodeRef(name: nodeName, location: currentLocation))
                    advance()
                } else if case .number(let n) = currentToken {
                    nodes.append(ParsedNodeRef(name: String(Int(n)), location: currentLocation))
                    advance()
                }
            }

            // For transistors, parse model name
            if type == .mosfet || type == .bjt || type == .jfet || type == .diode {
                if case .identifier(let model) = currentToken {
                    modelName = model
                    advance()
                }
            }
        }

        // Parse parameters
        while !isAtEnd && !isNewline {
            if case .identifier(let paramName) = currentToken {
                let lower = paramName.lowercased()
                advance()
                if case .equals = currentToken {
                    advance()
                    let value = try parseParameterValue()
                    params[lower] = value
                } else if (type == .voltageSource || type == .currentSource),
                          lower == "dc" || lower == "ac" {
                    // SPICE source syntax: V1 n1 n2 dc <value> ac <value>
                    // "dc <value>" sets the DC voltage/current
                    // "ac <value>" sets the AC magnitude
                    if case .number(let n) = currentToken {
                        if lower == "dc" {
                            params["v"] = .numeric(n)
                        } else {
                            params["ac"] = .numeric(n)
                        }
                        advance()
                    } else if case .identifier(let valStr) = currentToken,
                              let n = parseNumberFromIdentifier(valStr) {
                        if lower == "dc" {
                            params["v"] = .numeric(n)
                        } else {
                            params["ac"] = .numeric(n)
                        }
                        advance()
                    }
                } else if (type == .voltageSource || type == .currentSource),
                          lower == "pulse" {
                    // PULSE(v1 v2 td tr tf pw per)
                    try parseSourcePulse(into: &params)
                } else if (type == .voltageSource || type == .currentSource),
                          lower == "sin" || lower == "sine" {
                    // SIN(vo va freq td theta)
                    try parseSourceSine(into: &params)
                } else {
                    // Positional value (like resistance value for R, or gain for E)
                    if let v = parseNumberFromIdentifier(paramName) {
                        if type == .resistor && params["r"] == nil {
                            params["r"] = .numeric(v)
                        } else if type == .vcvs && params["e"] == nil {
                            params["e"] = .numeric(v)
                        } else if type == .vccs && params["g"] == nil {
                            params["g"] = .numeric(v)
                        } else if type == .cccs && params["f"] == nil {
                            params["f"] = .numeric(v)
                        } else if type == .ccvs && params["h"] == nil {
                            params["h"] = .numeric(v)
                        }
                    }
                }
            } else if case .number(let n) = currentToken {
                // Positional value
                if type == .resistor && params["r"] == nil {
                    params["r"] = .numeric(n)
                } else if type == .capacitor && params["c"] == nil {
                    params["c"] = .numeric(n)
                } else if type == .inductor && params["l"] == nil {
                    params["l"] = .numeric(n)
                } else if (type == .voltageSource || type == .currentSource) && params["v"] == nil {
                    // Bare positional DC value for sources: V1 n1 n2 5
                    params["v"] = .numeric(n)
                } else if type == .vcvs && params["e"] == nil {
                    params["e"] = .numeric(n)
                } else if type == .vccs && params["g"] == nil {
                    params["g"] = .numeric(n)
                } else if type == .cccs && params["f"] == nil {
                    params["f"] = .numeric(n)
                } else if type == .ccvs && params["h"] == nil {
                    params["h"] = .numeric(n)
                }
                advance()
            } else {
                advance()
            }
        }

        components.append(ParsedComponent(
            name: name,
            type: type,
            nodes: nodes,
            modelName: modelName,
            parameters: params,
            location: loc
        ))
    }

    private func parseNumberFromIdentifier(_ str: String) -> Double? {
        // Try to parse identifiers like "1k", "10u", etc.
        var numStr = ""
        var suffixStr = ""
        var inSuffix = false

        for char in str {
            if !inSuffix && (char.isNumber || char == ".") {
                numStr.append(char)
            } else {
                inSuffix = true
                suffixStr.append(char)
            }
        }

        guard let base = Double(numStr) else { return nil }

        let scale: Double
        switch suffixStr.lowercased() {
        case "t": scale = 1e12
        case "g": scale = 1e9
        case "meg", "x": scale = 1e6
        case "k": scale = 1e3
        case "m": scale = 1e-3
        case "u": scale = 1e-6
        case "n": scale = 1e-9
        case "p": scale = 1e-12
        case "f": scale = 1e-15
        case "": scale = 1.0
        default: scale = 1.0
        }

        return base * scale
    }

    /// Parse PULSE(v1 v2 td tr tf pw per) parameters.
    private mutating func parseSourcePulse(into params: inout [String: ParsedParameterValue]) throws {
        // Expect '(' after PULSE
        guard case .leftParen = currentToken else { return }
        advance()

        let keys = ["v1", "v2", "td", "tr", "tf", "pw", "per"]
        for key in keys {
            if case .rightParen = currentToken { break }
            if case .number(let n) = currentToken {
                params[key] = .numeric(n)
                advance()
            } else if case .identifier(let id) = currentToken,
                      let n = parseNumberFromIdentifier(id) {
                params[key] = .numeric(n)
                advance()
            }
        }

        if case .rightParen = currentToken { advance() }
    }

    /// Parse SIN(vo va freq td theta) parameters.
    private mutating func parseSourceSine(into params: inout [String: ParsedParameterValue]) throws {
        guard case .leftParen = currentToken else { return }
        advance()

        let keys = ["vo", "va", "freq", "td", "phase"]
        for key in keys {
            if case .rightParen = currentToken { break }
            if case .number(let n) = currentToken {
                params[key] = .numeric(n)
                advance()
            } else if case .identifier(let id) = currentToken,
                      let n = parseNumberFromIdentifier(id) {
                params[key] = .numeric(n)
                advance()
            }
        }

        if case .rightParen = currentToken { advance() }
    }

    private mutating func parseParameterValue() throws -> ParsedParameterValue {
        switch currentToken {
        case .number(let n):
            advance()
            return .numeric(n)
        case .identifier(let id):
            advance()
            // Check if it's a number with suffix
            if let n = parseNumberFromIdentifier(id) {
                return .numeric(n)
            }
            // It's an expression reference
            return .expression(.identifier(id))
        case .string(let s):
            advance()
            return .string(s)
        case .leftBrace:
            return try parseExpressionValue()
        default:
            throw ParserDiagnostic.error("Expected parameter value", at: currentLocation)
        }
    }

    private mutating func parseExpressionValue() throws -> ParsedParameterValue {
        guard case .leftBrace = currentToken else {
            throw ParserDiagnostic.error("Expected '{'", at: currentLocation)
        }
        advance()

        let expr = try parseExpression()

        guard case .rightBrace = currentToken else {
            throw ParserDiagnostic.error("Expected '}'", at: currentLocation)
        }
        advance()

        return .expression(expr)
    }

    private mutating func parseExpression() throws -> ParsedExpression {
        try parseAdditiveExpression()
    }

    private mutating func parseAdditiveExpression() throws -> ParsedExpression {
        var left = try parseMultiplicativeExpression()

        while !isAtEnd {
            if case .plus = currentToken {
                advance()
                let right = try parseMultiplicativeExpression()
                left = .binaryOp(.add, left, right)
            } else if case .minus = currentToken {
                advance()
                let right = try parseMultiplicativeExpression()
                left = .binaryOp(.subtract, left, right)
            } else {
                break
            }
        }

        return left
    }

    private mutating func parseMultiplicativeExpression() throws -> ParsedExpression {
        var left = try parsePowerExpression()

        while !isAtEnd {
            if case .asterisk = currentToken {
                advance()
                let right = try parsePowerExpression()
                left = .binaryOp(.multiply, left, right)
            } else if case .slash = currentToken {
                advance()
                let right = try parsePowerExpression()
                left = .binaryOp(.divide, left, right)
            } else {
                break
            }
        }

        return left
    }

    private mutating func parsePowerExpression() throws -> ParsedExpression {
        let base = try parseUnaryExpression()

        if !isAtEnd, case .caret = currentToken {
            advance()
            let exponent = try parsePowerExpression()
            return .binaryOp(.power, base, exponent)
        }

        return base
    }

    private mutating func parseUnaryExpression() throws -> ParsedExpression {
        if case .minus = currentToken {
            advance()
            let expr = try parsePrimaryExpression()
            return .unaryOp(.negate, expr)
        }
        return try parsePrimaryExpression()
    }

    private mutating func parsePrimaryExpression() throws -> ParsedExpression {
        switch currentToken {
        case .number(let n):
            advance()
            return .literal(n)
        case .identifier(let name):
            advance()
            // Check for function call
            if case .leftParen = currentToken {
                advance()
                var args: [ParsedExpression] = []
                while !isAtEnd {
                    if case .rightParen = currentToken { break }

                    args.append(try parseExpression())
                    if case .comma = currentToken {
                        advance()
                    }
                }
                if case .rightParen = currentToken {
                    advance()
                }
                return .functionCall(name: name, arguments: args)
            }
            // Check if it's a number with suffix
            if let n = parseNumberFromIdentifier(name) {
                return .literal(n)
            }
            return .identifier(name)
        case .leftParen:
            advance()
            let expr = try parseExpression()
            if case .rightParen = currentToken {
                advance()
            }
            return expr
        default:
            throw ParserDiagnostic.error("Unexpected token in expression: \(currentToken)", at: currentLocation)
        }
    }

    private mutating func parseSubcircuit(location: SourceLocation?) async throws {
        guard case .identifier(let name) = currentToken else {
            throw ParserDiagnostic.error("Expected subcircuit name", at: currentLocation)
        }
        advance()

        // Parse ports
        var ports: [String] = []
        while !isAtEnd && !isNewline && !isParameterStart {
            if case .identifier(let port) = currentToken {
                ports.append(port)
                advance()
            } else if case .number(let n) = currentToken {
                ports.append(String(Int(n)))
                advance()
            } else {
                break
            }
        }

        // Parse parameters
        var params: [String: ParsedParameterValue] = [:]
        if case .identifier(let id) = currentToken, id.lowercased() == "params" {
            advance()
            if case .colon = currentToken { advance() }
            while !isAtEnd && !isNewline {
                if case .identifier(let pname) = currentToken {
                    advance()
                    if case .equals = currentToken {
                        advance()
                        params[pname] = try parseParameterValue()
                    }
                } else {
                    break
                }
            }
        }

        skipNewlinesAndComments()

        // Parse subcircuit body
        var bodyComponents: [ParsedComponent] = []
        var bodyModels: [ParsedModel] = []
        var bodySubcircuits: [ParsedSubcircuit] = []
        var bodyParams: [String: ParsedExpression] = [:]

        // Save current state
        let savedComponents = components
        let savedModels = models
        let savedSubcircuits = subcircuits
        let savedParams = parameters

        components = []
        models = []
        subcircuits = []
        parameters = [:]

        // Parse until .ends
        while !isAtEnd {
            if case .directive(let dir) = currentToken {
                if dir == "ends" {
                    advance()
                    skipToEndOfLine()
                    break
                }
            }
            try await parseStatement()
        }

        bodyComponents = components
        bodyModels = models
        bodySubcircuits = subcircuits
        bodyParams = parameters

        // Restore state
        components = savedComponents
        models = savedModels
        subcircuits = savedSubcircuits
        parameters = savedParams

        let body = ParsedNetlistBody(
            components: bodyComponents,
            models: bodyModels,
            subcircuits: bodySubcircuits,
            parameters: bodyParams
        )

        subcircuits.append(ParsedSubcircuit(
            name: name,
            ports: ports,
            parameters: params,
            body: body,
            location: location
        ))
    }

    private mutating func parseModel(location: SourceLocation?) throws {
        guard case .identifier(let name) = currentToken else {
            throw ParserDiagnostic.error("Expected model name", at: currentLocation)
        }
        advance()

        guard case .identifier(let typeStr) = currentToken else {
            throw ParserDiagnostic.error("Expected model type", at: currentLocation)
        }
        advance()

        guard let type = ModelType(rawValue: typeStr.uppercased()) else {
            throw ParserDiagnostic.error("Unknown model type: \(typeStr)", at: currentLocation)
        }

        var level: Int?
        var params: [String: ParsedParameterValue] = [:]

        // Skip optional parenthesis
        if case .leftParen = currentToken {
            advance()
        }

        while !isAtEnd && !isNewline {
            if case .rightParen = currentToken {
                advance()
                break
            }
            if case .identifier(let pname) = currentToken {
                advance()
                if case .equals = currentToken {
                    advance()
                    let value = try parseParameterValue()
                    if pname.lowercased() == "level" {
                        if case .numeric(let n) = value {
                            level = Int(n)
                        }
                    } else {
                        params[pname.lowercased()] = value
                    }
                }
            } else if case .continuation = currentToken {
                advance()
            } else {
                advance()
            }
        }

        models.append(ParsedModel(
            name: name,
            type: type,
            level: level,
            parameters: params,
            location: location
        ))
    }

    private mutating func parseParam(location: SourceLocation?) throws {
        while !isAtEnd && !isNewline {
            if case .identifier(let name) = currentToken {
                advance()
                if case .equals = currentToken {
                    advance()
                    if case .number(let n) = currentToken {
                        parameters[name] = .literal(n)
                        advance()
                    } else if case .identifier(let id) = currentToken {
                        if let n = parseNumberFromIdentifier(id) {
                            parameters[name] = .literal(n)
                        } else {
                            parameters[name] = .identifier(id)
                        }
                        advance()
                    } else if case .leftBrace = currentToken {
                        advance()
                        parameters[name] = try parseExpression()
                        if case .rightBrace = currentToken {
                            advance()
                        }
                    }
                }
            } else {
                advance()
            }
        }
    }

    private mutating func parseInclude(location: SourceLocation?) async throws {
        var path = ""
        if case .string(let s) = currentToken {
            path = s
            advance()
        } else if case .identifier(let s) = currentToken {
            path = s
            advance()
        }

        skipToEndOfLine()

        // Resolve include if enabled
        if configuration.resolveIncludes {
            // Check include depth
            if includeDepth >= configuration.maxIncludeDepth {
                diagnostics.append(.error(
                    "Maximum include depth (\(configuration.maxIncludeDepth)) exceeded",
                    at: location
                ))
                return
            }

            do {
                let content = try await fileResolver.resolveInclude(path: path, relativeTo: fileName)
                try await parseIncludedContent(content, fileName: path)
            } catch {
                diagnostics.append(.error(
                    "Failed to include '\(path)': \(error)",
                    at: location
                ))
            }
        } else {
            controls.append(.include(path: path, location: location))
        }
    }

    /// Parses included file content and merges it into the current state.
    private mutating func parseIncludedContent(_ content: String, fileName: String) async throws {
        var includedParser = SPICEParserImpl(
            source: content,
            fileName: fileName,
            configuration: configuration,
            fileResolver: fileResolver,
            includeDepth: includeDepth + 1
        )

        let result = await includedParser.parse()

        // Merge results
        if let netlist = result.netlist {
            components.append(contentsOf: netlist.components)
            models.append(contentsOf: netlist.models)
            subcircuits.append(contentsOf: netlist.subcircuits)
            analyses.append(contentsOf: netlist.analyses)
            controls.append(contentsOf: netlist.controls)
            for (key, value) in netlist.parameters {
                parameters[key] = value
            }
            for (key, value) in netlist.initialConditions {
                initialConditions[key] = value
            }
            for (key, value) in netlist.nodeSets {
                nodeSets[key] = value
            }
            globalNodes.append(contentsOf: netlist.globalNodes)
        }

        // Propagate diagnostics
        diagnostics.append(contentsOf: result.diagnostics)
    }

    private mutating func parseLib(location: SourceLocation?) async throws {
        var path = ""
        var section: String?

        if case .string(let s) = currentToken {
            path = s
            advance()
        } else if case .identifier(let s) = currentToken {
            path = s
            advance()
        }

        if case .identifier(let s) = currentToken {
            section = s
            advance()
        }

        skipToEndOfLine()

        // Resolve library if enabled
        if configuration.resolveIncludes {
            // Check include depth
            if includeDepth >= configuration.maxIncludeDepth {
                diagnostics.append(.error(
                    "Maximum include depth (\(configuration.maxIncludeDepth)) exceeded",
                    at: location
                ))
                return
            }

            do {
                let content = try await fileResolver.resolveLibrary(
                    path: path,
                    section: section,
                    relativeTo: fileName
                )
                try await parseIncludedContent(content, fileName: path)
            } catch {
                diagnostics.append(.error(
                    "Failed to include library '\(path)' section '\(section ?? "default")': \(error)",
                    at: location
                ))
            }
        } else {
            controls.append(.library(path: path, section: section, location: location))
        }
    }

    private mutating func parseTransientAnalysis(location: SourceLocation?) throws {
        var stopTime: ParsedParameterValue = .numeric(1e-6)
        var stepTime: ParsedParameterValue?
        var startTime: ParsedParameterValue?

        if case .number(let n) = currentToken {
            stepTime = .numeric(n)
            advance()
        } else if case .identifier(let id) = currentToken {
            if let n = parseNumberFromIdentifier(id) {
                stepTime = .numeric(n)
            }
            advance()
        }

        if case .number(let n) = currentToken {
            stopTime = .numeric(n)
            advance()
        } else if case .identifier(let id) = currentToken {
            if let n = parseNumberFromIdentifier(id) {
                stopTime = .numeric(n)
            }
            advance()
        }

        if case .number(let n) = currentToken {
            startTime = .numeric(n)
            advance()
        }

        analyses.append(.transient(TransientAnalysisSpec(
            stopTime: stopTime,
            stepTime: stepTime,
            startTime: startTime
        )))
        skipToEndOfLine()
    }

    private mutating func parseACAnalysis(location: SourceLocation?) throws {
        var scaleType: ACScaleType = .decade
        var points = 10
        var startFreq: ParsedParameterValue = .numeric(1.0)
        var stopFreq: ParsedParameterValue = .numeric(1e6)

        if case .identifier(let scale) = currentToken {
            switch scale.lowercased() {
            case "dec": scaleType = .decade
            case "oct": scaleType = .octave
            case "lin": scaleType = .linear
            default: break
            }
            advance()
        }

        if case .number(let n) = currentToken {
            points = Int(n)
            advance()
        }

        if case .number(let n) = currentToken {
            startFreq = .numeric(n)
            advance()
        } else if case .identifier(let id) = currentToken {
            if let n = parseNumberFromIdentifier(id) {
                startFreq = .numeric(n)
            }
            advance()
        }

        if case .number(let n) = currentToken {
            stopFreq = .numeric(n)
            advance()
        } else if case .identifier(let id) = currentToken {
            if let n = parseNumberFromIdentifier(id) {
                stopFreq = .numeric(n)
            }
            advance()
        }

        analyses.append(.ac(ACAnalysisSpec(
            scaleType: scaleType,
            numberOfPoints: points,
            startFrequency: startFreq,
            stopFrequency: stopFreq
        )))
        skipToEndOfLine()
    }

    private mutating func parseDCAnalysis(location: SourceLocation?) throws {
        guard case .identifier(let source) = currentToken else {
            throw ParserDiagnostic.error("Expected source name for DC sweep", at: currentLocation)
        }
        advance()

        var start: ParsedParameterValue = .numeric(0)
        var stop: ParsedParameterValue = .numeric(1)
        var step: ParsedParameterValue = .numeric(0.1)

        if case .number(let n) = currentToken {
            start = .numeric(n)
            advance()
        }
        if case .number(let n) = currentToken {
            stop = .numeric(n)
            advance()
        }
        if case .number(let n) = currentToken {
            step = .numeric(n)
            advance()
        }

        analyses.append(.dc(DCAnalysisSpec(
            source: source,
            startValue: start,
            stopValue: stop,
            stepValue: step
        )))
        skipToEndOfLine()
    }

    /// Parses .noise directive: .noise V(out[,ref]) Vin dec|oct|lin np fstart fstop
    private mutating func parseNoiseAnalysis(location: SourceLocation?) throws {
        // Parse output specification V(node) or V(node,ref)
        guard case .identifier(let vName) = currentToken, vName.lowercased() == "v" else {
            throw ParserDiagnostic.error("Expected V(node) for noise output", at: currentLocation)
        }
        advance()

        guard case .leftParen = currentToken else {
            throw ParserDiagnostic.error("Expected '(' after V", at: currentLocation)
        }
        advance()

        guard case .identifier(let outputNode) = currentToken else {
            throw ParserDiagnostic.error("Expected output node name", at: currentLocation)
        }
        advance()

        var referenceNode: String?
        if case .comma = currentToken {
            advance()
            if case .identifier(let ref) = currentToken {
                referenceNode = ref
                advance()
            }
        }

        guard case .rightParen = currentToken else {
            throw ParserDiagnostic.error("Expected ')' after node specification", at: currentLocation)
        }
        advance()

        // Parse input source
        guard case .identifier(let inputSource) = currentToken else {
            throw ParserDiagnostic.error("Expected input source name", at: currentLocation)
        }
        advance()

        // Parse sweep type
        var scaleType: ACScaleType = .decade
        if case .identifier(let scale) = currentToken {
            switch scale.lowercased() {
            case "dec": scaleType = .decade
            case "oct": scaleType = .octave
            case "lin": scaleType = .linear
            default: break
            }
            advance()
        }

        // Parse number of points
        var points = 10
        if case .number(let n) = currentToken {
            points = Int(n)
            advance()
        }

        // Parse start frequency
        var startFreq: ParsedParameterValue = .numeric(1.0)
        if case .number(let n) = currentToken {
            startFreq = .numeric(n)
            advance()
        } else if case .identifier(let id) = currentToken {
            if let n = parseNumberFromIdentifier(id) {
                startFreq = .numeric(n)
            }
            advance()
        }

        // Parse stop frequency
        var stopFreq: ParsedParameterValue = .numeric(1e6)
        if case .number(let n) = currentToken {
            stopFreq = .numeric(n)
            advance()
        } else if case .identifier(let id) = currentToken {
            if let n = parseNumberFromIdentifier(id) {
                stopFreq = .numeric(n)
            }
            advance()
        }

        analyses.append(.noise(NoiseAnalysisSpec(
            outputNode: outputNode,
            referenceNode: referenceNode,
            inputSource: inputSource,
            scaleType: scaleType,
            numberOfPoints: points,
            startFrequency: startFreq,
            stopFrequency: stopFreq
        )))
        skipToEndOfLine()
    }

    /// Parses .tf directive: .tf V(out) Vin
    private mutating func parseTransferFunctionAnalysis(location: SourceLocation?) throws {
        // Parse output specification
        guard case .identifier(let vName) = currentToken, vName.lowercased() == "v" else {
            throw ParserDiagnostic.error("Expected V(output) for transfer function", at: currentLocation)
        }
        advance()

        guard case .leftParen = currentToken else {
            throw ParserDiagnostic.error("Expected '(' after V", at: currentLocation)
        }
        advance()

        guard case .identifier(let output) = currentToken else {
            throw ParserDiagnostic.error("Expected output node name", at: currentLocation)
        }
        advance()

        guard case .rightParen = currentToken else {
            throw ParserDiagnostic.error("Expected ')' after output node", at: currentLocation)
        }
        advance()

        // Parse input source
        guard case .identifier(let input) = currentToken else {
            throw ParserDiagnostic.error("Expected input source name", at: currentLocation)
        }
        advance()

        analyses.append(.transferFunction(TransferFunctionSpec(
            output: "V(\(output))",
            input: input
        )))
        skipToEndOfLine()
    }

    /// Parses .sens directive: .sens V(out) [ac dec np fstart fstop]
    private mutating func parseSensitivityAnalysis(location: SourceLocation?) throws {
        // Parse output specification
        guard case .identifier(let vName) = currentToken, vName.lowercased() == "v" else {
            throw ParserDiagnostic.error("Expected V(output) for sensitivity", at: currentLocation)
        }
        advance()

        guard case .leftParen = currentToken else {
            throw ParserDiagnostic.error("Expected '(' after V", at: currentLocation)
        }
        advance()

        guard case .identifier(let output) = currentToken else {
            throw ParserDiagnostic.error("Expected output node name", at: currentLocation)
        }
        advance()

        guard case .rightParen = currentToken else {
            throw ParserDiagnostic.error("Expected ')' after output node", at: currentLocation)
        }
        advance()

        // Check for optional AC specification
        var acSpec: ACAnalysisSpec?
        if case .identifier(let acId) = currentToken, acId.lowercased() == "ac" {
            advance()

            var scaleType: ACScaleType = .decade
            if case .identifier(let scale) = currentToken {
                switch scale.lowercased() {
                case "dec": scaleType = .decade
                case "oct": scaleType = .octave
                case "lin": scaleType = .linear
                default: break
                }
                advance()
            }

            var points = 10
            if case .number(let n) = currentToken {
                points = Int(n)
                advance()
            }

            var startFreq: ParsedParameterValue = .numeric(1.0)
            if case .number(let n) = currentToken {
                startFreq = .numeric(n)
                advance()
            } else if case .identifier(let id) = currentToken {
                if let n = parseNumberFromIdentifier(id) {
                    startFreq = .numeric(n)
                }
                advance()
            }

            var stopFreq: ParsedParameterValue = .numeric(1e6)
            if case .number(let n) = currentToken {
                stopFreq = .numeric(n)
                advance()
            } else if case .identifier(let id) = currentToken {
                if let n = parseNumberFromIdentifier(id) {
                    stopFreq = .numeric(n)
                }
                advance()
            }

            acSpec = ACAnalysisSpec(
                scaleType: scaleType,
                numberOfPoints: points,
                startFrequency: startFreq,
                stopFrequency: stopFreq
            )
        }

        analyses.append(.sensitivity(SensitivitySpec(
            output: "V(\(output))",
            acSpec: acSpec
        )))
        skipToEndOfLine()
    }

    /// Parses .four directive: .four freq V(out) [V(out2) ...]
    private mutating func parseFourierAnalysis(location: SourceLocation?) throws {
        // Parse fundamental frequency
        var frequency: ParsedParameterValue = .numeric(1e6)
        if case .number(let n) = currentToken {
            frequency = .numeric(n)
            advance()
        } else if case .identifier(let id) = currentToken {
            if let n = parseNumberFromIdentifier(id) {
                frequency = .numeric(n)
            }
            advance()
        }

        // Parse output variables
        var outputs: [String] = []
        while !isAtEnd && !isNewline {
            if case .identifier(let vName) = currentToken, vName.lowercased() == "v" {
                advance()
                if case .leftParen = currentToken {
                    advance()
                    if case .identifier(let node) = currentToken {
                        outputs.append("V(\(node))")
                        advance()
                    }
                    if case .rightParen = currentToken {
                        advance()
                    }
                }
            } else if case .identifier(let iName) = currentToken, iName.lowercased() == "i" {
                advance()
                if case .leftParen = currentToken {
                    advance()
                    if case .identifier(let device) = currentToken {
                        outputs.append("I(\(device))")
                        advance()
                    }
                    if case .rightParen = currentToken {
                        advance()
                    }
                }
            } else {
                advance()
            }
        }

        analyses.append(.fourier(FourierSpec(
            frequency: frequency,
            outputs: outputs
        )))
        skipToEndOfLine()
    }

    /// Parses .pz directive: .pz node1 node2 node3 node4 vol|cur pz|pol|zer
    private mutating func parsePoleZeroAnalysis(location: SourceLocation?) throws {
        // Parse 4 nodes
        var nodes: [String] = []
        for _ in 0..<4 {
            if case .identifier(let node) = currentToken {
                nodes.append(node)
                advance()
            } else if case .number(let n) = currentToken {
                nodes.append(String(Int(n)))
                advance()
            } else {
                throw ParserDiagnostic.error("Expected 4 nodes for pole-zero analysis", at: currentLocation)
            }
        }

        guard nodes.count == 4 else {
            throw ParserDiagnostic.error("Expected 4 nodes for pole-zero analysis", at: currentLocation)
        }

        // Parse transfer type (vol or cur)
        var transferType: PoleZeroSpec.TransferType = .voltage
        if case .identifier(let typeStr) = currentToken {
            switch typeStr.lowercased() {
            case "vol": transferType = .voltage
            case "cur": transferType = .current
            default: break
            }
            advance()
        }

        // Parse analysis type (pz, pol, or zer)
        var analysisType: PoleZeroSpec.PoleZeroType = .both
        if case .identifier(let modeStr) = currentToken {
            switch modeStr.lowercased() {
            case "pz": analysisType = .both
            case "pol": analysisType = .poles
            case "zer": analysisType = .zeros
            default: break
            }
            advance()
        }

        analyses.append(.poleZero(PoleZeroSpec(
            inputNode: nodes[0],
            inputReference: nodes[1],
            outputNode: nodes[2],
            outputReference: nodes[3],
            transferType: transferType,
            analysisType: analysisType
        )))
        skipToEndOfLine()
    }

    /// Parses .mc directive: .mc runs analysis [seed=n]
    private mutating func parseMonteCarloAnalysis(location: SourceLocation?) throws {
        // Parse number of iterations
        var iterations = 100
        if case .number(let n) = currentToken {
            iterations = Int(n)
            advance()
        }

        // Parse inner analysis
        guard case .identifier(let analysisName) = currentToken else {
            throw ParserDiagnostic.error("Expected analysis type for Monte Carlo", at: currentLocation)
        }
        advance()

        // Parse the inner analysis based on type
        var innerAnalysis: ParsedAnalysisCommand?
        switch analysisName.lowercased() {
        case "tran":
            var stopTime: ParsedParameterValue = .numeric(1e-6)
            var stepTime: ParsedParameterValue?

            if case .number(let n) = currentToken {
                stepTime = .numeric(n)
                advance()
            } else if case .identifier(let id) = currentToken {
                if let n = parseNumberFromIdentifier(id) {
                    stepTime = .numeric(n)
                }
                advance()
            }

            if case .number(let n) = currentToken {
                stopTime = .numeric(n)
                advance()
            } else if case .identifier(let id) = currentToken {
                if let n = parseNumberFromIdentifier(id) {
                    stopTime = .numeric(n)
                }
                advance()
            }

            innerAnalysis = .transient(TransientAnalysisSpec(
                stopTime: stopTime,
                stepTime: stepTime
            ))

        case "ac":
            var scaleType: ACScaleType = .decade
            var points = 10
            var startFreq: ParsedParameterValue = .numeric(1.0)
            var stopFreq: ParsedParameterValue = .numeric(1e6)

            if case .identifier(let scale) = currentToken {
                switch scale.lowercased() {
                case "dec": scaleType = .decade
                case "oct": scaleType = .octave
                case "lin": scaleType = .linear
                default: break
                }
                advance()
            }

            if case .number(let n) = currentToken {
                points = Int(n)
                advance()
            }

            if case .number(let n) = currentToken {
                startFreq = .numeric(n)
                advance()
            }

            if case .number(let n) = currentToken {
                stopFreq = .numeric(n)
                advance()
            }

            innerAnalysis = .ac(ACAnalysisSpec(
                scaleType: scaleType,
                numberOfPoints: points,
                startFrequency: startFreq,
                stopFrequency: stopFreq
            ))

        case "dc":
            guard case .identifier(let source) = currentToken else {
                throw ParserDiagnostic.error("Expected source name for DC sweep", at: currentLocation)
            }
            advance()

            var start: ParsedParameterValue = .numeric(0)
            var stop: ParsedParameterValue = .numeric(1)
            var step: ParsedParameterValue = .numeric(0.1)

            if case .number(let n) = currentToken {
                start = .numeric(n)
                advance()
            }
            if case .number(let n) = currentToken {
                stop = .numeric(n)
                advance()
            }
            if case .number(let n) = currentToken {
                step = .numeric(n)
                advance()
            }

            innerAnalysis = .dc(DCAnalysisSpec(
                source: source,
                startValue: start,
                stopValue: stop,
                stepValue: step
            ))

        default:
            throw ParserDiagnostic.error("Unsupported analysis type for Monte Carlo: \(analysisName)", at: currentLocation)
        }

        // Parse optional seed
        var seed: Int?
        while !isAtEnd && !isNewline {
            if case .identifier(let paramName) = currentToken {
                if paramName.lowercased() == "seed" {
                    advance()
                    if case .equals = currentToken {
                        advance()
                    }
                    if case .number(let n) = currentToken {
                        seed = Int(n)
                        advance()
                    }
                }
            } else {
                advance()
            }
        }

        if let inner = innerAnalysis {
            analyses.append(.monteCarlo(MonteCarloSpec(
                analysis: inner,
                iterations: iterations,
                seed: seed
            )))
        }
        skipToEndOfLine()
    }

    /// Parses .meas directive: .meas tran|ac|dc name <measurement_type> <parameters>
    private mutating func parseMeasure(location: SourceLocation?) throws {
        // Parse analysis type
        var analysisType: OutputAnalysisType = .transient
        if case .identifier(let typeStr) = currentToken {
            switch typeStr.lowercased() {
            case "dc": analysisType = .dc
            case "ac": analysisType = .ac
            case "tran": analysisType = .transient
            default: break
            }
            advance()
        }

        // Parse result name
        guard case .identifier(let resultName) = currentToken else {
            throw ParserDiagnostic.error("Expected measurement result name", at: currentLocation)
        }
        advance()

        // Parse measurement type keyword or trigger/target
        var measureType: MeasureType?

        if case .identifier(let keyword) = currentToken {
            let lowerKeyword = keyword.lowercased()

            switch lowerKeyword {
            case "trig":
                // Delay measurement: trig ... targ ...
                advance()
                let trigVar = try parseOutputVariable()
                var trigVal: ParsedParameterValue = .numeric(0.5)

                // Parse val=
                while !isAtEnd && !isNewline {
                    if case .identifier(let param) = currentToken {
                        let lowerParam = param.lowercased()
                        if lowerParam == "val" {
                            advance()
                            if case .equals = currentToken { advance() }
                            trigVal = try parseParameterValue()
                        } else if lowerParam == "targ" {
                            break
                        } else {
                            advance()
                        }
                    } else {
                        break
                    }
                }

                // Parse targ
                guard case .identifier(let targ) = currentToken, targ.lowercased() == "targ" else {
                    throw ParserDiagnostic.error("Expected 'targ' in delay measurement", at: currentLocation)
                }
                advance()

                let targVar = try parseOutputVariable()
                var targVal: ParsedParameterValue = .numeric(0.5)

                // Parse val=
                while !isAtEnd && !isNewline {
                    if case .identifier(let param) = currentToken {
                        if param.lowercased() == "val" {
                            advance()
                            if case .equals = currentToken { advance() }
                            targVal = try parseParameterValue()
                        } else {
                            advance()
                        }
                    } else {
                        break
                    }
                }

                measureType = .delay(
                    variable1: trigVar,
                    value1: trigVal,
                    variable2: targVar,
                    value2: targVal
                )

            case "when":
                advance()
                let expr = try parseExpression()
                measureType = .when(condition: expr, target: nil)

            case "find":
                advance()
                let variable = try parseOutputVariable()
                var atValue: ParsedParameterValue = .numeric(0)

                if case .identifier(let atKeyword) = currentToken, atKeyword.lowercased() == "at" {
                    advance()
                    if case .equals = currentToken { advance() }
                    atValue = try parseParameterValue()
                }

                measureType = .find(variable: variable, at: atValue)

            case "avg", "average":
                advance()
                let variable = try parseOutputVariable()
                let (from, to) = try parseMeasureRange()
                measureType = .average(variable: variable, from: from, to: to)

            case "rms":
                advance()
                let variable = try parseOutputVariable()
                let (from, to) = try parseMeasureRange()
                measureType = .rms(variable: variable, from: from, to: to)

            case "min":
                advance()
                let variable = try parseOutputVariable()
                let (from, to) = try parseMeasureRange()
                measureType = .min(variable: variable, from: from, to: to)

            case "max":
                advance()
                let variable = try parseOutputVariable()
                let (from, to) = try parseMeasureRange()
                measureType = .max(variable: variable, from: from, to: to)

            case "pp":
                advance()
                let variable = try parseOutputVariable()
                let (from, to) = try parseMeasureRange()
                measureType = .peakToPeak(variable: variable, from: from, to: to)

            case "integ":
                advance()
                let variable = try parseOutputVariable()
                let (from, to) = try parseMeasureRange()
                measureType = .integral(variable: variable, from: from, to: to)

            case "rise_time":
                advance()
                let variable = try parseOutputVariable()
                var low = 0.1
                var high = 0.9

                while !isAtEnd && !isNewline {
                    if case .identifier(let param) = currentToken {
                        let lowerParam = param.lowercased()
                        if lowerParam == "low" || lowerParam == "from" {
                            advance()
                            if case .equals = currentToken { advance() }
                            if case .number(let n) = currentToken {
                                low = n
                                advance()
                            }
                        } else if lowerParam == "high" || lowerParam == "to" {
                            advance()
                            if case .equals = currentToken { advance() }
                            if case .number(let n) = currentToken {
                                high = n
                                advance()
                            }
                        } else {
                            advance()
                        }
                    } else {
                        break
                    }
                }

                measureType = .riseTime(variable: variable, lowThreshold: low, highThreshold: high)

            case "fall_time":
                advance()
                let variable = try parseOutputVariable()
                var high = 0.9
                var low = 0.1

                while !isAtEnd && !isNewline {
                    if case .identifier(let param) = currentToken {
                        let lowerParam = param.lowercased()
                        if lowerParam == "high" || lowerParam == "from" {
                            advance()
                            if case .equals = currentToken { advance() }
                            if case .number(let n) = currentToken {
                                high = n
                                advance()
                            }
                        } else if lowerParam == "low" || lowerParam == "to" {
                            advance()
                            if case .equals = currentToken { advance() }
                            if case .number(let n) = currentToken {
                                low = n
                                advance()
                            }
                        } else {
                            advance()
                        }
                    } else {
                        break
                    }
                }

                measureType = .fallTime(variable: variable, highThreshold: high, lowThreshold: low)

            default:
                // Try to parse as simple expression-based measurement
                let variable = try parseOutputVariable()
                measureType = .average(variable: variable, from: nil, to: nil)
            }
        }

        if let mType = measureType {
            controls.append(.measure(MeasureSpec(
                analysisType: analysisType,
                resultName: resultName,
                measureType: mType,
                location: location
            )))
        }

        skipToEndOfLine()
    }

    /// Helper to parse optional from=/to= range for measure commands
    private mutating func parseMeasureRange() throws -> (ParsedParameterValue?, ParsedParameterValue?) {
        var from: ParsedParameterValue?
        var to: ParsedParameterValue?

        while !isAtEnd && !isNewline {
            if case .identifier(let param) = currentToken {
                let lowerParam = param.lowercased()
                if lowerParam == "from" {
                    advance()
                    if case .equals = currentToken { advance() }
                    from = try parseParameterValue()
                } else if lowerParam == "to" {
                    advance()
                    if case .equals = currentToken { advance() }
                    to = try parseParameterValue()
                } else {
                    break
                }
            } else {
                break
            }
        }

        return (from, to)
    }

    private mutating func parseTemp(location: SourceLocation?) throws {
        if case .number(let n) = currentToken {
            controls.append(.temp(value: .numeric(n), location: location))
            advance()
        }
        skipToEndOfLine()
    }

    private mutating func parseIC(location: SourceLocation?) throws {
        while !isAtEnd && !isNewline {
            if case .identifier(let node) = currentToken {
                advance()
                if case .equals = currentToken {
                    advance()
                    if case .number(let v) = currentToken {
                        initialConditions[node] = .numeric(v)
                        advance()
                    }
                }
            } else {
                advance()
            }
        }
    }

    private mutating func parseNodeset(location: SourceLocation?) throws {
        while !isAtEnd && !isNewline {
            if case .identifier(let node) = currentToken {
                advance()
                if case .equals = currentToken {
                    advance()
                    if case .number(let v) = currentToken {
                        nodeSets[node] = .numeric(v)
                        advance()
                    }
                }
            } else {
                advance()
            }
        }
    }

    private mutating func parseGlobal(location: SourceLocation?) throws {
        while !isAtEnd && !isNewline {
            if case .identifier(let node) = currentToken {
                globalNodes.append(node)
                advance()
            } else {
                advance()
            }
        }
    }

    private mutating func parseOption(location: SourceLocation?) throws {
        while !isAtEnd && !isNewline {
            if case .identifier(let name) = currentToken {
                advance()
                var value: ParsedParameterValue?
                if case .equals = currentToken {
                    advance()
                    value = try parseParameterValue()
                }
                controls.append(.option(name: name, value: value, location: location))
            } else {
                advance()
            }
        }
    }

    private mutating func parsePrint(location: SourceLocation?) throws {
        var analysisType: OutputAnalysisType = .dc

        if case .identifier(let type) = currentToken {
            switch type.lowercased() {
            case "dc": analysisType = .dc
            case "ac": analysisType = .ac
            case "tran": analysisType = .transient
            default: break
            }
            advance()
        }

        var variables: [OutputVariable] = []
        while !isAtEnd && !isNewline {
            do {
                let v = try parseOutputVariable()
                variables.append(v)
            } catch {
                // Skip unrecognized tokens in output variable list
                advance()
            }
        }

        controls.append(.print(PrintSpec(
            analysisType: analysisType,
            variables: variables,
            location: location
        )))
    }

    private mutating func parsePlot(location: SourceLocation?) throws {
        var analysisType: OutputAnalysisType = .dc

        if case .identifier(let type) = currentToken {
            switch type.lowercased() {
            case "dc": analysisType = .dc
            case "ac": analysisType = .ac
            case "tran": analysisType = .transient
            default: break
            }
            advance()
        }

        var variables: [OutputVariable] = []
        while !isAtEnd && !isNewline {
            do {
                let v = try parseOutputVariable()
                variables.append(v)
            } catch {
                // Skip unrecognized tokens in output variable list
                advance()
            }
        }

        controls.append(.plot(PlotSpec(
            analysisType: analysisType,
            variables: variables,
            location: location
        )))
    }

    private mutating func parseSave(location: SourceLocation?) throws {
        var variables: [String] = []
        while !isAtEnd && !isNewline {
            if case .identifier(let name) = currentToken {
                variables.append(name)
                advance()
            } else {
                advance()
            }
        }
        controls.append(.save(variables: variables, location: location))
    }

    private mutating func parseOutputVariable() throws -> OutputVariable {
        guard case .identifier(let name) = currentToken else {
            throw ParserDiagnostic.error("Expected variable name", at: currentLocation)
        }
        advance()

        // Check for V(...) or I(...)
        let lower = name.lowercased()
        if lower == "v" {
            if case .leftParen = currentToken {
                advance()
                guard case .identifier(let node) = currentToken else {
                    throw ParserDiagnostic.error("Expected node name", at: currentLocation)
                }
                advance()
                var refNode: String?
                if case .comma = currentToken {
                    advance()
                    if case .identifier(let ref) = currentToken {
                        refNode = ref
                        advance()
                    }
                }
                if case .rightParen = currentToken {
                    advance()
                }
                return .voltage(node: node, reference: refNode)
            }
        } else if lower == "i" {
            if case .leftParen = currentToken {
                advance()
                guard case .identifier(let device) = currentToken else {
                    throw ParserDiagnostic.error("Expected device name", at: currentLocation)
                }
                advance()
                if case .rightParen = currentToken {
                    advance()
                }
                return .current(device: device)
            }
        }

        // Generic identifier
        return .voltage(node: name, reference: nil)
    }

    // MARK: - Helper Methods

    private var currentToken: SPICEToken {
        guard current < tokens.count else { return .endOfFile }
        return tokens[current].token
    }

    private var currentLocation: SourceLocation? {
        guard current < tokens.count else { return nil }
        return tokens[current].location
    }

    private var isAtEnd: Bool {
        current >= tokens.count || currentToken == .endOfFile
    }

    private var isNewline: Bool {
        currentToken == .newline
    }

    private var isParameterStart: Bool {
        if case .identifier(let id) = currentToken {
            // Check if next is =
            if current + 1 < tokens.count {
                if case .equals = tokens[current + 1].token {
                    return true
                }
            }
            // Check for "params:"
            if id.lowercased() == "params" {
                return true
            }
        }
        return false
    }

    private mutating func advance() {
        if current < tokens.count {
            current += 1
        }
    }

    private mutating func skipNewlinesAndComments() {
        while !isAtEnd {
            switch currentToken {
            case .newline, .comment, .continuation:
                advance()
            default:
                return
            }
        }
    }

    private mutating func skipToEndOfLine() {
        while !isAtEnd && !isNewline {
            advance()
        }
        if isNewline {
            advance()
        }
    }

    private mutating func synchronize() {
        // Skip to next line on error
        while !isAtEnd && !isNewline {
            advance()
        }
        if isNewline {
            advance()
        }
    }
}

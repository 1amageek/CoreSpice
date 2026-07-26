import CoreSpiceParsedIR
import CoreSpiceParser
import Foundation

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
                                       "ic", "nodeset", "global", "temp", "func", "function",
                                       "probe", "save", "measure", "meas", "if", "elseif", "elif",
                                       "else", "endif"]
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
    private let conditionalParameterExpressions: [String: String]

    private var tokens: [SPICEToken.Located] = []
    private var current = 0
    private var diagnostics: [ParserDiagnostic] = []

    // Parse state
    private var components: [ParsedComponent] = []
    private var models: [ParsedModel] = []
    private var subcircuits: [ParsedSubcircuit] = []
    private var analyses: [ParsedAnalysisCommand] = []
    private var controls: [ParsedControlStatement] = []
    private var parameterDefinitions: [ParsedParameterDefinition] = []
    private var parameters: [String: ParsedExpression] = [:]
    private var preprocessingEvents: [SPICEPreprocessingEvent] = []
    private var initialConditions: [String: ParsedParameterValue] = [:]
    private var nodeSets: [String: ParsedParameterValue] = [:]
    private var globalNodes: [String] = []
    private var title: String?

    init(
        source: String,
        fileName: String?,
        configuration: ParserConfiguration,
        fileResolver: any FileResolver,
        includeDepth: Int = 0,
        conditionalParameterExpressions: [String: String] = [:]
    ) {
        self.source = source
        self.fileName = fileName
        self.configuration = configuration
        self.fileResolver = fileResolver
        self.includeDepth = includeDepth
        self.conditionalParameterExpressions = conditionalParameterExpressions
    }

    mutating func parse() async -> ParseResult {
        let conditionalResult = SPICEConditionalPreprocessor().process(
            source: source,
            fileName: fileName,
            initialParameters: conditionalParameterExpressions
        )
        preprocessingEvents.append(contentsOf: conditionalResult.events)
        diagnostics.append(contentsOf: conditionalResult.diagnostics)

        // Tokenize
        var lexer = SPICELexer(
            source: conditionalResult.source,
            fileName: fileName,
            configuration: configuration
        )
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
            parameterDefinitions: parameterDefinitions,
            parameters: parameters,
            preprocessingEvents: preprocessingEvents,
            initialConditions: initialConditions,
            nodeSets: nodeSets,
            globalNodes: globalNodes,
            sourcePath: fileName
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
        case "endl":
            skipToEndOfLine()
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
        case "probe":
            try parseProbe(location: loc)
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
        case "func", "function":
            try parseFunction(location: loc)
        case "alter":
            try parseAlter(location: loc)
        case "hdl":
            try parseHDL(location: loc)
        default:
            throw ParserDiagnostic.error("Unsupported SPICE directive: .\(name)", at: loc)
        }
    }

    private mutating func parseAlter(location: SourceLocation?) throws {
        guard case .identifier(let target) = currentToken else {
            throw ParserDiagnostic.error("Expected alter target", at: currentLocation)
        }
        advance()
        guard case .identifier(let parameter) = currentToken else {
            throw ParserDiagnostic.error("Expected altered parameter name", at: currentLocation)
        }
        advance()
        if case .equals = currentToken {
            advance()
        }
        guard let value = try parseParameterValueIfPresent() else {
            throw ParserDiagnostic.error("Expected altered parameter value", at: currentLocation)
        }
        controls.append(.alter(AlterSpec(
            target: target,
            parameter: parameter,
            value: value,
            location: location
        )))
        skipToEndOfLine()
    }

    private mutating func parseHDL(location: SourceLocation?) throws {
        let path: String
        switch currentToken {
        case .string(let value), .identifier(let value):
            path = value
            advance()
        default:
            throw ParserDiagnostic.error("Expected HDL source path", at: currentLocation)
        }
        controls.append(.hdl(path: path, location: location))
        skipToEndOfLine()
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

        // For subcircuit instances, collect all node tokens until the parameter
        // section; the final identifier is the subcircuit name. Node names may be
        // numeric (e.g. ground "0"), so numbers are collected as nodes too.
        if type == .subcircuitInstance {
            var tokens: [String] = []
            while !isAtEnd && !isNewline && !isParameterStart {
                if case .identifier(let id) = currentToken {
                    tokens.append(id)
                    advance()
                } else if case .number(let n) = currentToken {
                    tokens.append(String(Int(n)))
                    advance()
                } else if case .invalidNumericLiteral(let text) = currentToken {
                    throw ParserDiagnostic.error("Invalid numeric literal '\(text)'", at: currentLocation)
                } else if case .invalidNumericSuffix(let suffix) = currentToken {
                    throw ParserDiagnostic.error("Unknown numeric suffix '\(suffix)'", at: currentLocation)
                } else {
                    break
                }
            }
            // The last token is the subcircuit name; the rest are connection nodes.
            if let subcktName = tokens.popLast() {
                modelName = subcktName
            }
            nodes = tokens.map { ParsedNodeRef(name: $0, location: loc) }
        } else if type == .cccs || type == .ccvs {
            try parseCurrentControlledSourceComponent(
                type: type,
                nodes: &nodes,
                params: &params
            )
        } else if type == .currentSwitch {
            try parseCurrentControlledSwitchComponent(
                nodes: &nodes,
                modelName: &modelName,
                params: &params
            )
        } else {
            // Parse fixed number of nodes
            for _ in 0..<nodeCount {
                if case .identifier(let nodeName) = currentToken {
                    nodes.append(ParsedNodeRef(name: nodeName, location: currentLocation))
                    advance()
                } else if case .number(let n) = currentToken {
                    nodes.append(ParsedNodeRef(name: String(Int(n)), location: currentLocation))
                    advance()
                } else if case .invalidNumericLiteral(let text) = currentToken {
                    throw ParserDiagnostic.error("Invalid numeric literal '\(text)'", at: currentLocation)
                } else if case .invalidNumericSuffix(let suffix) = currentToken {
                    throw ParserDiagnostic.error("Unknown numeric suffix '\(suffix)'", at: currentLocation)
                }
            }

            // For model-backed devices, parse model name
            if type == .mosfet || type == .bjt || type == .jfet || type == .mesfet
                || type == .diode || type == .uniformRC
                || type == .switch_ || type == .currentSwitch {
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
                    // Current sources carry their DC value under "i"; voltage sources under "v".
                    let dcKey = (type == .currentSource) ? "i" : "v"
                    if let value = try parseSignedNumber() {
                        params[lower == "dc" ? dcKey : "ac"] = .numeric(value)
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
                    if let key = positionalKey(for: type, existing: params) {
                        if let value = parseNumberFromIdentifier(paramName) {
                            params[key] = .numeric(value)
                        } else {
                            params[key] = .expression(.identifier(paramName))
                        }
                    }
                }
            } else if case .number(let n) = currentToken {
                // Positional value (resistance for R, DC value for a source, etc.)
                if let key = positionalKey(for: type, existing: params) {
                    params[key] = .numeric(n)
                }
                advance()
            } else if case .invalidNumericLiteral(let text) = currentToken {
                throw ParserDiagnostic.error("Invalid numeric literal '\(text)'", at: currentLocation)
            } else if case .invalidNumericSuffix(let suffix) = currentToken {
                throw ParserDiagnostic.error("Unknown numeric suffix '\(suffix)'", at: currentLocation)
            } else if isSignToken(currentToken) {
                // Signed positional value, e.g. a negative source DC value (V1 n1 n2 -2).
                if let value = try parseSignedNumber(), let key = positionalKey(for: type, existing: params) {
                    params[key] = .numeric(value)
                }
            } else if case .leftBrace = currentToken {
                if let key = positionalKey(for: type, existing: params) {
                    params[key] = try parseExpressionValue()
                } else {
                    _ = try parseExpressionValue()
                }
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

    private mutating func parseCurrentControlledSourceComponent(
        type: ComponentType,
        nodes: inout [ParsedNodeRef],
        params: inout [String: ParsedParameterValue]
    ) throws {
        nodes.append(try parseRequiredNodeRef())
        nodes.append(try parseRequiredNodeRef())

        let controlLocation = currentLocation
        if case .number = currentToken {
            nodes.append(try parseRequiredNodeRef())
            nodes.append(try parseRequiredNodeRef())
            let gainKey = type == .cccs ? "f" : "h"
            try parseControlledGainParameter(into: &params, key: gainKey)
            return
        }
        guard case .identifier(let controlName) = currentToken else {
            throw ParserDiagnostic.error("Expected controlling source or sense node", at: currentLocation)
        }
        advance()

        let gainKey = type == .cccs ? "f" : "h"
        if currentControlledElementUsesExplicitSenseTerminals() {
            nodes.append(ParsedNodeRef(name: controlName, location: controlLocation))
            nodes.append(try parseRequiredNodeRef())
        } else {
            params["control_source"] = .string(controlName)
        }
        try parseControlledGainParameter(into: &params, key: gainKey)
    }

    private mutating func parseCurrentControlledSwitchComponent(
        nodes: inout [ParsedNodeRef],
        modelName: inout String?,
        params: inout [String: ParsedParameterValue]
    ) throws {
        nodes.append(try parseRequiredNodeRef())
        nodes.append(try parseRequiredNodeRef())

        let controlLocation = currentLocation
        if case .number = currentToken {
            nodes.append(try parseRequiredNodeRef())
            nodes.append(try parseRequiredNodeRef())
            modelName = try parseRequiredIdentifier(message: "Expected current switch model name")
            return
        }
        guard case .identifier(let controlName) = currentToken else {
            throw ParserDiagnostic.error("Expected controlling source or sense node", at: currentLocation)
        }
        advance()

        if currentControlledElementUsesExplicitSenseTerminals() {
            nodes.append(ParsedNodeRef(name: controlName, location: controlLocation))
            nodes.append(try parseRequiredNodeRef())
        } else {
            params["control_source"] = .string(controlName)
        }

        modelName = try parseRequiredIdentifier(message: "Expected current switch model name")
    }

    private mutating func parseRequiredNodeRef() throws -> ParsedNodeRef {
        let location = currentLocation
        if case .identifier(let nodeName) = currentToken {
            advance()
            return ParsedNodeRef(name: nodeName, location: location)
        }
        if case .number(let n) = currentToken {
            advance()
            return ParsedNodeRef(name: String(Int(n)), location: location)
        }
        if case .invalidNumericLiteral(let text) = currentToken {
            throw ParserDiagnostic.error("Invalid numeric literal '\(text)'", at: currentLocation)
        }
        if case .invalidNumericSuffix(let suffix) = currentToken {
            throw ParserDiagnostic.error("Unknown numeric suffix '\(suffix)'", at: currentLocation)
        }
        throw ParserDiagnostic.error("Expected node name", at: currentLocation)
    }

    private mutating func parseRequiredIdentifier(message: String) throws -> String {
        guard case .identifier(let value) = currentToken else {
            throw ParserDiagnostic.error(message, at: currentLocation)
        }
        advance()
        return value
    }

    private mutating func parseControlledGainParameter(
        into params: inout [String: ParsedParameterValue],
        key: String
    ) throws {
        if case .identifier(let parameterName) = currentToken,
           parameterName.lowercased() == key,
           current + 1 < tokens.count,
           case .equals = tokens[current + 1].token {
            advance()
            advance()
            params[key] = try parseParameterValue()
            return
        }
        params[key] = try parseParameterValue()
    }

    /// Reads an optional leading +/- sign followed by a numeric token and
    /// returns the signed value. The lexer emits a separate `.minus`/`.plus`
    /// token before a number, so source values and positional component values
    /// (which are not expressions) must reassemble the sign here.
    private mutating func parseSignedNumber() throws -> Double? {
        var sign = 1.0
        if case .minus = currentToken {
            sign = -1.0
            advance()
        } else if case .plus = currentToken {
            advance()
        }
        if case .number(let n) = currentToken {
            advance()
            return sign * n
        }
        if case .invalidNumericLiteral(let text) = currentToken {
            throw ParserDiagnostic.error("Invalid numeric literal '\(text)'", at: currentLocation)
        }
        if case .invalidNumericSuffix(let suffix) = currentToken {
            throw ParserDiagnostic.error("Unknown numeric suffix '\(suffix)'", at: currentLocation)
        }
        if case .identifier(let s) = currentToken, let n = parseNumberFromIdentifier(s) {
            advance()
            return sign * n
        }
        return nil
    }

    private func isSignToken(_ token: SPICEToken) -> Bool {
        if case .minus = token { return true }
        if case .plus = token { return true }
        return false
    }

    /// The parameter key a bare positional value maps to for a given component
    /// type, or nil if that type has no (further) positional value.
    private func positionalKey(for type: ComponentType, existing params: [String: ParsedParameterValue]) -> String? {
        switch type {
        case .resistor: return params["r"] == nil ? "r" : nil
        case .capacitor: return params["c"] == nil ? "c" : nil
        case .inductor: return params["l"] == nil ? "l" : nil
        case .voltageSource: return params["v"] == nil ? "v" : nil
        case .currentSource: return params["i"] == nil ? "i" : nil
        case .vcvs: return params["e"] == nil ? "e" : nil
        case .vccs: return params["g"] == nil ? "g" : nil
        case .cccs: return params["f"] == nil ? "f" : nil
        case .ccvs: return params["h"] == nil ? "h" : nil
        case .coupledInductors: return params["k"] == nil ? "k" : nil
        default: return nil
        }
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

        guard let base = Double(numStr), base.isFinite else { return nil }

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

        let value = base * scale
        guard value.isFinite else { return nil }
        return value
    }

    private mutating func parseNumericTokenIfPresent() throws -> Double? {
        switch currentToken {
        case .number(let value):
            advance()
            return value
        case .invalidNumericLiteral(let text):
            throw ParserDiagnostic.error("Invalid numeric literal '\(text)'", at: currentLocation)
        case .invalidNumericSuffix(let suffix):
            throw ParserDiagnostic.error("Unknown numeric suffix '\(suffix)'", at: currentLocation)
        case .identifier(let text):
            guard let value = parseNumberFromIdentifier(text) else {
                return nil
            }
            advance()
            return value
        default:
            return nil
        }
    }

    private mutating func parseAnalysisPointCount(default defaultValue: Int) throws -> Int {
        if isAtEnd || isNewline {
            return defaultValue
        }
        let location = currentLocation
        guard let value = try parseNumericTokenIfPresent() else {
            throw ParserDiagnostic.error("Expected numeric analysis point count", at: currentLocation)
        }
        return try parsePositiveInteger(value, label: "analysis point count", at: location)
    }

    private func parsePositiveInteger(
        _ value: Double,
        label: String,
        at location: SourceLocation?
    ) throws -> Int {
        guard value.isFinite,
              value > 0,
              value.rounded(.towardZero) == value,
              value < Double(Int.max) else {
            throw ParserDiagnostic.error("Expected positive integer \(label)", at: location)
        }
        return Int(value)
    }

    private func parseNonnegativeInteger(
        _ value: Double,
        label: String,
        at location: SourceLocation?
    ) throws -> Int {
        guard value.isFinite,
              value >= 0,
              value.rounded(.towardZero) == value,
              value < Double(Int.max) else {
            throw ParserDiagnostic.error("Expected nonnegative integer \(label)", at: location)
        }
        return Int(value)
    }

    private mutating func parseParameterValueIfPresent() throws -> ParsedParameterValue? {
        if isAtEnd || isNewline {
            return nil
        }

        switch currentToken {
        case .number, .invalidNumericLiteral, .invalidNumericSuffix,
             .identifier, .string, .leftBrace, .minus, .plus:
            return try parseParameterValue()
        default:
            return nil
        }
    }

    /// Parse PULSE(v1 v2 td tr tf pw per) parameters.
    private mutating func parseSourcePulse(into params: inout [String: ParsedParameterValue]) throws {
        // Expect '(' after PULSE
        guard case .leftParen = currentToken else { return }
        advance()

        let keys = ["v1", "v2", "td", "tr", "tf", "pw", "per"]
        for key in keys {
            if case .rightParen = currentToken { break }
            if let n = try parseNumericTokenIfPresent() {
                params[key] = .numeric(n)
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
            if let n = try parseNumericTokenIfPresent() {
                params[key] = .numeric(n)
            }
        }

        if case .rightParen = currentToken { advance() }
    }

    private mutating func parseParameterValue() throws -> ParsedParameterValue {
        // Handle unary minus/plus before a number (e.g. vto=-0.7)
        if case .minus = currentToken {
            advance()
            switch currentToken {
            case .number(let n):
                advance()
                return .numeric(-n)
            case .invalidNumericLiteral(let text):
                throw ParserDiagnostic.error("Invalid numeric literal '\(text)'", at: currentLocation)
            case .invalidNumericSuffix(let suffix):
                throw ParserDiagnostic.error("Unknown numeric suffix '\(suffix)'", at: currentLocation)
            case .identifier(let id):
                advance()
                if let n = parseNumberFromIdentifier(id) {
                    return .numeric(-n)
                }
                return .expression(.unaryOperation(.negate, .identifier(id)))
            default:
                throw ParserDiagnostic.error("Expected number after '-'", at: currentLocation)
            }
        }
        if case .plus = currentToken {
            advance()
            // Unary plus is a no-op; parse the next value
            return try parseParameterValue()
        }

        switch currentToken {
        case .number(let n):
            advance()
            return .numeric(n)
        case .invalidNumericLiteral(let text):
            throw ParserDiagnostic.error("Invalid numeric literal '\(text)'", at: currentLocation)
        case .invalidNumericSuffix(let suffix):
            throw ParserDiagnostic.error("Unknown numeric suffix '\(suffix)'", at: currentLocation)
        case .identifier(let id):
            if current + 1 < tokens.count, case .leftParen = tokens[current + 1].token {
                return .expression(try parseExpression())
            }
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
        var expressionParser = SPICEExpressionTokenParser(tokens: tokens, currentIndex: current)
        let expression = try expressionParser.parseExpression()
        current = expressionParser.currentIndex
        return expression
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
            } else if case .invalidNumericLiteral(let text) = currentToken {
                throw ParserDiagnostic.error("Invalid numeric literal '\(text)'", at: currentLocation)
            } else if case .invalidNumericSuffix(let suffix) = currentToken {
                throw ParserDiagnostic.error("Unknown numeric suffix '\(suffix)'", at: currentLocation)
            } else {
                break
            }
        }

        // Parse parameters
        var params: [String: ParsedParameterValue] = [:]
        if case .identifier(let id) = currentToken, isParamsKeyword(id) {
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
        var bodyParameterDefinitions: [ParsedParameterDefinition] = []

        // Save current state
        let savedComponents = components
        let savedModels = models
        let savedSubcircuits = subcircuits
        let savedParams = parameters
        let savedParameterDefinitions = parameterDefinitions

        components = []
        models = []
        subcircuits = []
        parameters = [:]
        parameterDefinitions = []

        // Parse until .ends. Skip leading newlines/comments before the .ends
        // check, otherwise parseStatement (which skips them itself) would consume
        // the .ends directive and the loop would swallow the rest of the file.
        while !isAtEnd {
            skipNewlinesAndComments()
            if isAtEnd { break }
            if case .directive(let dir) = currentToken, dir == "ends" {
                advance()
                skipToEndOfLine()
                break
            }
            try await parseStatement()
        }

        bodyComponents = components
        bodyModels = models
        bodySubcircuits = subcircuits
        bodyParams = parameters
        bodyParameterDefinitions = parameterDefinitions

        // Restore state
        components = savedComponents
        models = savedModels
        subcircuits = savedSubcircuits
        parameters = savedParams
        parameterDefinitions = savedParameterDefinitions

        let body = ParsedNetlistBody(
            components: bodyComponents,
            models: bodyModels,
            subcircuits: bodySubcircuits,
            parameters: bodyParams,
            parameterDefinitions: bodyParameterDefinitions
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
                    let expression = try parseParameterExpression()
                    parameters[name] = expression
                    parameterDefinitions.append(ParsedParameterDefinition(
                        name: name,
                        value: expression,
                        location: location
                    ))
                }
            } else {
                advance()
            }
        }
    }

    private mutating func parseParameterExpression() throws -> ParsedExpression {
        if case .leftBrace = currentToken {
            advance()
            let expression = try parseExpression()
            guard case .rightBrace = currentToken else {
                throw ParserDiagnostic.error("Expected '}' after parameter expression", at: currentLocation)
            }
            advance()
            return expression
        }
        return try parseExpression()
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

        controls.append(.include(path: path, location: location))

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
                let childPath = try await resolvedChildPath(path, relativeTo: fileName)
                try await parseIncludedContent(
                    content,
                    fileName: childPath
                )
            } catch {
                diagnostics.append(.error(
                    "Failed to include '\(path)': \(error)",
                    at: location
                ))
            }
        }
    }

    /// Parses included file content and merges it into the current state.
    private mutating func parseIncludedContent(_ content: String, fileName: String) async throws {
        var inheritedConditionalParameters = conditionalParameterExpressions
        for (name, expression) in parameters {
            inheritedConditionalParameters[name.lowercased()] = expression.description
        }

        var includedParser = SPICEParserImpl(
            source: content,
            fileName: fileName,
            configuration: configuration,
            fileResolver: fileResolver,
            includeDepth: includeDepth + 1,
            conditionalParameterExpressions: inheritedConditionalParameters
        )

        let result = await includedParser.parse()

        // Merge results
        if let netlist = result.netlist {
            components.append(contentsOf: netlist.components)
            models.append(contentsOf: netlist.models)
            subcircuits.append(contentsOf: netlist.subcircuits)
            analyses.append(contentsOf: netlist.analyses)
            controls.append(contentsOf: netlist.controls)
            parameterDefinitions.append(contentsOf: netlist.parameterDefinitions)
            preprocessingEvents.append(contentsOf: netlist.preprocessingEvents)
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

        controls.append(.library(path: path, section: section, location: location))

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
                let childPath = try await resolvedChildPath(path, relativeTo: fileName)
                try await parseIncludedContent(
                    content,
                    fileName: childPath
                )
            } catch {
                diagnostics.append(.error(
                    "Failed to include library '\(path)' section '\(section ?? "default")': \(error)",
                    at: location
                ))
            }
        }
    }

    private func resolvedChildPath(_ path: String, relativeTo base: String?) async throws -> String {
        if let resolver = fileResolver as? any ResolvedPathProvidingFileResolver {
            return try await resolver.resolvedPath(for: path, relativeTo: base)
        }
        guard !path.hasPrefix("/"), let base else {
            return path
        }
        return URL(fileURLWithPath: base)
            .deletingLastPathComponent()
            .appendingPathComponent(path)
            .path
    }

    private mutating func parseTransientAnalysis(location: SourceLocation?) throws {
        var stopTime: ParsedParameterValue = .numeric(1e-6)
        var stepTime: ParsedParameterValue?
        var startTime: ParsedParameterValue?
        var maxStep: ParsedParameterValue?
        var useInitialConditions = false

        if !isCurrentTransientUICToken, let value = try parseParameterValueIfPresent() {
            stepTime = value
        }

        if !isCurrentTransientUICToken, let value = try parseParameterValueIfPresent() {
            stopTime = value
        }

        if !isCurrentTransientUICToken, let value = try parseParameterValueIfPresent() {
            startTime = value
        }

        while !isAtEnd && !isNewline {
            if case .identifier(let id) = currentToken, id.lowercased() == "uic" {
                useInitialConditions = true
                advance()
                continue
            }
            if maxStep == nil, let value = try parseParameterValueIfPresent() {
                maxStep = value
                continue
            }
            throw ParserDiagnostic.error(
                "Unsupported transient analysis token: \(tokenEvidenceText(currentToken))",
                at: currentLocation
            )
        }

        analyses.append(.transient(TransientAnalysisSpec(
            stopTime: stopTime,
            stepTime: stepTime,
            startTime: startTime,
            maxStep: maxStep,
            useInitialConditions: useInitialConditions
        )))
        skipToEndOfLine()
    }

    private var isCurrentTransientUICToken: Bool {
        if case .identifier(let id) = currentToken {
            return id.lowercased() == "uic"
        }
        return false
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

        points = try parseAnalysisPointCount(default: points)

        if let value = try parseParameterValueIfPresent() {
            startFreq = value
        }

        if let value = try parseParameterValueIfPresent() {
            stopFreq = value
        }

        analyses.append(.ac(try ACAnalysisSpec(
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

        if let value = try parseParameterValueIfPresent() {
            start = value
        }
        if let value = try parseParameterValueIfPresent() {
            stop = value
        }
        if let value = try parseParameterValueIfPresent() {
            step = value
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
        points = try parseAnalysisPointCount(default: points)

        // Parse start frequency
        var startFreq: ParsedParameterValue = .numeric(1.0)
        if let value = try parseParameterValueIfPresent() {
            startFreq = value
        }

        // Parse stop frequency
        var stopFreq: ParsedParameterValue = .numeric(1e6)
        if let value = try parseParameterValueIfPresent() {
            stopFreq = value
        }

        analyses.append(.noise(try NoiseAnalysisSpec(
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

            guard case .identifier(let scale) = currentToken else {
                throw ParserDiagnostic.error(
                    "Expected AC sensitivity scale dec, oct, or lin",
                    at: currentLocation
                )
            }
            let scaleType: ACScaleType
            switch scale.lowercased() {
            case "dec": scaleType = .decade
            case "oct": scaleType = .octave
            case "lin": scaleType = .linear
            default:
                throw ParserDiagnostic.error(
                    "Expected AC sensitivity scale dec, oct, or lin",
                    at: currentLocation
                )
            }
            advance()

            let pointsLocation = currentLocation
            guard let rawPoints = try parseNumericTokenIfPresent() else {
                throw ParserDiagnostic.error(
                    "Expected AC sensitivity point count",
                    at: pointsLocation
                )
            }
            let points = try parsePositiveInteger(
                rawPoints,
                label: "AC sensitivity point count",
                at: pointsLocation
            )

            let startLocation = currentLocation
            guard let rawStartFrequency = try parseNumericTokenIfPresent() else {
                throw ParserDiagnostic.error(
                    "Expected AC sensitivity start frequency",
                    at: startLocation
                )
            }
            let startFreq: ParsedParameterValue = .numeric(rawStartFrequency)

            let stopLocation = currentLocation
            guard let rawStopFrequency = try parseNumericTokenIfPresent() else {
                throw ParserDiagnostic.error(
                    "Expected AC sensitivity stop frequency",
                    at: stopLocation
                )
            }
            let stopFreq: ParsedParameterValue = .numeric(rawStopFrequency)

            acSpec = try ACAnalysisSpec(
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
        if let n = try parseNumericTokenIfPresent() {
            frequency = .numeric(n)
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
            } else if case .invalidNumericLiteral(let text) = currentToken {
                throw ParserDiagnostic.error("Invalid numeric literal '\(text)'", at: currentLocation)
            } else if case .invalidNumericSuffix(let suffix) = currentToken {
                throw ParserDiagnostic.error("Unknown numeric suffix '\(suffix)'", at: currentLocation)
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
            default:
                throw ParserDiagnostic.error(
                    "Expected pole-zero transfer type vol or cur",
                    at: currentLocation
                )
            }
            advance()
        } else {
            throw ParserDiagnostic.error(
                "Expected pole-zero transfer type vol or cur",
                at: currentLocation
            )
        }

        // Parse analysis type (pz, pol, or zer)
        var analysisType: PoleZeroSpec.PoleZeroType = .both
        if case .identifier(let modeStr) = currentToken {
            switch modeStr.lowercased() {
            case "pz": analysisType = .both
            case "pol": analysisType = .poles
            case "zer": analysisType = .zeros
            default:
                throw ParserDiagnostic.error(
                    "Expected pole-zero analysis type pz, pol, or zer",
                    at: currentLocation
                )
            }
            advance()
        } else {
            throw ParserDiagnostic.error(
                "Expected pole-zero analysis type pz, pol, or zer",
                at: currentLocation
            )
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
        let iterationsLocation = currentLocation
        if let n = try parseNumericTokenIfPresent() {
            iterations = try parsePositiveInteger(
                n,
                label: "Monte Carlo iteration count",
                at: iterationsLocation
            )
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

            if let n = try parseNumericTokenIfPresent() {
                stepTime = .numeric(n)
            }

            if let n = try parseNumericTokenIfPresent() {
                stopTime = .numeric(n)
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

            points = try parseAnalysisPointCount(default: points)

            if let n = try parseNumericTokenIfPresent() {
                startFreq = .numeric(n)
            }

            if let n = try parseNumericTokenIfPresent() {
                stopFreq = .numeric(n)
            }

            innerAnalysis = .ac(try ACAnalysisSpec(
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

            if let n = try parseNumericTokenIfPresent() {
                start = .numeric(n)
            }
            if let n = try parseNumericTokenIfPresent() {
                stop = .numeric(n)
            }
            if let n = try parseNumericTokenIfPresent() {
                step = .numeric(n)
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
                    let seedLocation = currentLocation
                    guard let n = try parseNumericTokenIfPresent() else {
                        throw ParserDiagnostic.error(
                            "Expected nonnegative integer Monte Carlo seed",
                            at: seedLocation
                        )
                    }
                    seed = try parseNonnegativeInteger(n, label: "Monte Carlo seed", at: seedLocation)
                }
            } else {
                advance()
            }
        }

        if let inner = innerAnalysis {
            analyses.append(.monteCarlo(try MonteCarloSpec(
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
            case "op": analysisType = .op
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

        guard case .identifier(let keyword) = currentToken else {
            throw ParserDiagnostic.error("Expected measurement type", at: currentLocation)
        }
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
                            if let n = try parseNumericTokenIfPresent() {
                                low = n
                            }
                        } else if lowerParam == "high" || lowerParam == "to" {
                            advance()
                            if case .equals = currentToken { advance() }
                            if let n = try parseNumericTokenIfPresent() {
                                high = n
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
                            if let n = try parseNumericTokenIfPresent() {
                                high = n
                            }
                        } else if lowerParam == "low" || lowerParam == "to" {
                            advance()
                            if case .equals = currentToken { advance() }
                            if let n = try parseNumericTokenIfPresent() {
                                low = n
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
            advance()
            measureType = .unsupported(
                keyword: lowerKeyword,
                arguments: collectRemainingLineTokenDescriptions(),
                reason: "Measurement keyword '\(keyword)' is not supported by CoreSpice"
            )
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

    private mutating func collectRemainingLineTokenDescriptions() -> [String] {
        var descriptions: [String] = []
        while !isAtEnd && !isNewline {
            descriptions.append(tokenEvidenceText(currentToken))
            advance()
        }
        return descriptions
    }

    private func tokenEvidenceText(_ token: SPICEToken) -> String {
        switch token {
        case .directive(let name):
            return ".\(name)"
        case .comment(let text):
            return text
        case .number(let value):
            return value.description
        case .identifier(let name):
            return name
        case .string(let value):
            return "\"\(value)\""
        case .invalidNumericLiteral(let text):
            return text
        case .invalidNumericSuffix(let suffix):
            return suffix
        default:
            return token.description
        }
    }

    /// Parses .func name(arg, ...) = expression.
    private mutating func parseFunction(location: SourceLocation?) throws {
        guard case .identifier(let name) = currentToken else {
            throw ParserDiagnostic.error("Expected function name", at: currentLocation)
        }
        advance()

        var parameters: [String] = []
        if case .leftParen = currentToken {
            advance()
            while !isAtEnd {
                if case .rightParen = currentToken {
                    advance()
                    break
                }
                if case .identifier(let parameter) = currentToken {
                    parameters.append(parameter)
                    advance()
                    if case .comma = currentToken {
                        advance()
                    }
                } else {
                    throw ParserDiagnostic.error("Expected function parameter name", at: currentLocation)
                }
            }
        }

        if case .equals = currentToken {
            advance()
        }

        let body = try parseParameterExpression()
        controls.append(.function(name: name, parameters: parameters, body: body, location: location))
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
        let value = try parseParameterValue()
        controls.append(.temp(value: value, location: location))
        skipToEndOfLine()
    }

    private mutating func parseIC(location: SourceLocation?) throws {
        while !isAtEnd && !isNewline {
            if let assignment = try parseNodeVoltageAssignment() {
                initialConditions[assignment.node] = assignment.value
                controls.append(.initialCondition(
                    node: assignment.node,
                    voltage: assignment.value,
                    location: location
                ))
            } else {
                advance()
            }
        }
    }

    private mutating func parseNodeset(location: SourceLocation?) throws {
        while !isAtEnd && !isNewline {
            if let assignment = try parseNodeVoltageAssignment() {
                nodeSets[assignment.node] = assignment.value
                controls.append(.nodeSet(
                    node: assignment.node,
                    voltage: assignment.value,
                    location: location
                ))
            } else {
                advance()
            }
        }
    }

    private mutating func parseNodeVoltageAssignment() throws -> (node: String, value: ParsedParameterValue)? {
        let saved = current
        var node: String?

        if case .identifier(let name) = currentToken, name.lowercased() == "v" {
            advance()
            guard case .leftParen = currentToken else {
                current = saved
                return nil
            }
            advance()
            if case .identifier(let parsedNode) = currentToken {
                node = parsedNode
                advance()
            } else if case .number(let numericNode) = currentToken {
                node = try parseNumericNodeName(numericNode)
                advance()
            } else if case .invalidNumericLiteral(let text) = currentToken {
                throw ParserDiagnostic.error("Invalid numeric literal '\(text)'", at: currentLocation)
            } else if case .invalidNumericSuffix(let suffix) = currentToken {
                throw ParserDiagnostic.error("Unknown numeric suffix '\(suffix)'", at: currentLocation)
            }
            guard case .rightParen = currentToken else {
                current = saved
                return nil
            }
            advance()
        } else if case .identifier(let parsedNode) = currentToken {
            node = parsedNode
            advance()
        }

        guard let node else {
            current = saved
            return nil
        }
        guard case .equals = currentToken else {
            current = saved
            return nil
        }
        advance()

        let value = try parseParameterValue()
        return (node: node, value: value)
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
            case "op": analysisType = .op
            default: break
            }
            advance()
        }

        var variables: [OutputVariable] = []
        while !isAtEnd && !isNewline {
            let v = try parseOutputVariable()
            variables.append(v)
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
            case "op": analysisType = .op
            default: break
            }
            advance()
        }

        var variables: [OutputVariable] = []
        while !isAtEnd && !isNewline {
            let v = try parseOutputVariable()
            variables.append(v)
        }

        controls.append(.plot(PlotSpec(
            analysisType: analysisType,
            variables: variables,
            location: location
        )))
    }

    private mutating func parseSave(location: SourceLocation?) throws {
        let variables = try parseOutputVariableTexts()
        controls.append(.save(variables: variables, location: location))
    }

    private mutating func parseProbe(location: SourceLocation?) throws {
        let variables = try parseOutputVariableTexts()
        controls.append(.probe(variables: variables, location: location))
    }

    private mutating func parseOutputVariableTexts() throws -> [String] {
        var variables: [String] = []
        while !isAtEnd && !isNewline {
            if let variable = try parseOutputVariableText() {
                variables.append(variable)
            } else {
                advance()
            }
        }
        return variables
    }

    private mutating func parseOutputVariableText() throws -> String? {
        guard case .identifier(let name) = currentToken else { return nil }
        advance()

        let lower = name.lowercased()
        if lower == "v" || lower == "i" {
            guard case .leftParen = currentToken else { return name }
            advance()
            var parts: [String] = []
            while !isAtEnd {
                if case .rightParen = currentToken {
                    advance()
                    break
                }
                if case .identifier(let value) = currentToken {
                    parts.append(value)
                    advance()
                } else if case .number(let numericValue) = currentToken {
                    parts.append(try parseNumericNodeName(numericValue))
                    advance()
                } else if case .comma = currentToken {
                    advance()
                } else {
                    break
                }
            }
            return "\(lower)(\(parts.joined(separator: ",")))"
        }

        return name
    }

    private mutating func parseOutputVariable() throws -> OutputVariable {
        if case .leftBrace = currentToken {
            advance()
            let expression = try parseExpression()
            guard case .rightBrace = currentToken else {
                throw ParserDiagnostic.error("Expected '}' after output expression", at: currentLocation)
            }
            advance()
            return .expression(expression)
        }

        guard case .identifier(let name) = currentToken else {
            throw ParserDiagnostic.error("Expected variable name", at: currentLocation)
        }
        advance()

        // Check for V(...) or I(...)
        let lower = name.lowercased()
        if ["mag", "magnitude", "phase", "ph", "real", "re", "imag", "im", "db"].contains(lower) {
            guard case .leftParen = currentToken else {
                throw ParserDiagnostic.error(
                    "Expected '(' after output modifier \(name)",
                    at: currentLocation
                )
            }
            advance()
            let inner = try parseOutputVariable()
            guard case .rightParen = currentToken else {
                throw ParserDiagnostic.error(
                    "Expected ')' after output modifier \(name)",
                    at: currentLocation
                )
            }
            advance()
            switch lower {
            case "mag", "magnitude":
                return .magnitude(inner)
            case "phase", "ph":
                return .phase(inner)
            case "real", "re":
                return .real(inner)
            case "imag", "im":
                return .imaginary(inner)
            default:
                return .dB(inner)
            }
        }
        if lower == "v" {
            if case .leftParen = currentToken {
                advance()
                guard let node = try parseOutputNodeName() else {
                    throw ParserDiagnostic.error("Expected node name", at: currentLocation)
                }
                var refNode: String?
                if case .comma = currentToken {
                    advance()
                    if let ref = try parseOutputNodeName() {
                        refNode = ref
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

    private mutating func parseOutputNodeName() throws -> String? {
        if case .identifier(let node) = currentToken {
            advance()
            return node
        }
        if case .number(let numericNode) = currentToken {
            let node = try parseNumericNodeName(numericNode)
            advance()
            return node
        }
        return nil
    }

    private func parseNumericNodeName(_ numericNode: Double) throws -> String {
        guard numericNode.isFinite,
              numericNode >= 0,
              numericNode.rounded(.towardZero) == numericNode else {
            throw ParserDiagnostic.error(
                "Numeric node names must be non-negative integers.",
                at: currentLocation
            )
        }
        return String(Int(numericNode))
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
        isParameterStart(at: current)
    }

    private func isParameterStart(at index: Int) -> Bool {
        guard index < tokens.count else {
            return false
        }
        if case .identifier(let id) = tokens[index].token {
            if index + 1 < tokens.count, case .equals = tokens[index + 1].token {
                return true
            }
            if isParamsKeyword(id) {
                return true
            }
        }
        return false
    }

    private func isParamsKeyword(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower == "params" || lower == "params:"
    }

    private func remainingPositionalFieldCountBeforeParameterStart() -> Int {
        var index = current
        var fieldCount = 0
        while index < tokens.count {
            let token = tokens[index].token
            if isLineEnd(token) || isParameterStart(at: index) {
                break
            }
            fieldCount += 1
            index = positionalFieldEndIndex(startingAt: index)
        }
        return fieldCount
    }

    private func currentControlledElementUsesExplicitSenseTerminals() -> Bool {
        let remainingFields = remainingPositionalFieldCountBeforeParameterStart()
        if remainingFields >= 2 {
            return true
        }
        guard remainingFields == 1 else {
            return false
        }
        let afterCandidateSenseNode = positionalFieldEndIndex(startingAt: current)
        return isParameterStart(at: afterCandidateSenseNode)
    }

    private func positionalFieldEndIndex(startingAt start: Int) -> Int {
        guard start < tokens.count else {
            return start
        }
        switch tokens[start].token {
        case .leftBrace:
            var index = start + 1
            var depth = 1
            while index < tokens.count, depth > 0 {
                switch tokens[index].token {
                case .leftBrace:
                    depth += 1
                case .rightBrace:
                    depth -= 1
                default:
                    break
                }
                index += 1
            }
            return index
        case .minus, .plus:
            return min(start + 2, tokens.count)
        default:
            return start + 1
        }
    }

    private func isLineEnd(_ token: SPICEToken) -> Bool {
        if case .newline = token {
            return true
        }
        if case .endOfFile = token {
            return true
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

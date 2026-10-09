import CoreSpiceParsedIR
import CoreSpiceParser
import Foundation

/// A parser for SPICE netlist files.
///
/// Implements the `NetlistParser` protocol to parse standard SPICE
/// and HSPICE netlist formats.
public struct SPICEParser: NetlistParser, SPICEProfileSourceParsing {

    public let formatIdentifier = "spice"
    public let fileExtensions = [".sp", ".cir", ".spice", ".net", ".spi"]
    public let formatName = "SPICE Netlist"

    public init() {}

    public func parse(document: SPICESourceDocument, configuration: ParserConfiguration,
                      fileResolver: any FileResolver) async -> ParseResult {
        var parser = SPICEParserImpl(document: document, configuration: configuration, fileResolver: fileResolver)
        do { return try await parser.parse() }
        catch { return ParseResult(errors: [.error(String(describing: error))]) }
    }

    /// Uses the ordinary grammar with cooperative accounting and strict resolver failure propagation.
    public func parseChecked(document: SPICESourceDocument, configuration: ParserConfiguration,
                             fileResolver: any FileResolver, work: any SPICESourceWorkAccounting,
                             initialParameters: [String: String] = [:]) async throws -> ParseResult {
        var parser = SPICEParserImpl(document: document, configuration: configuration,
            fileResolver: fileResolver, conditionalParameterExpressions: initialParameters, work: work)
        return try await parser.parse()
    }

    /// Uses the same grammar with owned storage and pre-await contextual resolution.
    public func parseProfile(document: SPICESourceDocument, configuration: ParserConfiguration,
                             environment: SPICEPreprocessingEnvironment,
                             resolver: any SPICEContextualFileResolver,
                             resources: any SPICESourceResourceAccounting) async throws -> SPICEOwnedParseResult {
        try resources.checkCancellation()
        guard configuration.resolveIncludes else {
            throw SPICEBoundedSourceError.unsupportedBudgetCapability("Disabled include resolution")
        }
        guard configuration.maxIncludeDepth >= 0,
              configuration.caseInsensitive == environment.caseInsensitive else {
            throw SPICEBoundedSourceError.invalidEnvironment
        }
        guard document.isInvocationAccounted, document.sourceKey != nil,
              let occurrence = document.occurrenceID else { throw SPICEBoundedSourceError.unaccountedSource }
        let registry = try SPICEProfileOccurrenceRegistry.admit(resources: resources)
        try await registry.insert(occurrence)
        var parser = SPICEParserImpl(document: document, configuration: configuration,
            fileResolver: NullFileResolver(), resources: resources, environment: environment,
            contextualResolver: resolver, occurrenceRegistry: registry)
        return try await parser.parseOwned()
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

    private let document: SPICESourceDocument
    private let environment: SPICEPreprocessingEnvironment?
    private let contextualResolver: (any SPICEContextualFileResolver)?
    private let occurrenceRegistry: SPICEProfileOccurrenceRegistry?
    private var coordinates: SPICEPhysicalSourceCoordinates?
    private var nextStatementOrdinal: UInt64 = 0
    private var activeStatementOrdinal: UInt64 = 0
    private var resolverFailed = false
    private let profileResources: (any SPICESourceResourceAccounting)?
    private var profileStorage: SPICEParseStorage?
    private let work: (any SPICESourceWorkAccounting)?
    private let selectedSection: String?
    private let source: String
    private let captureID: String?
    private let fileName: String?
    private let configuration: ParserConfiguration
    private let fileResolver: any FileResolver
    private let includeDepth: Int
    private let conditionalParameterExpressions: [String: String]

    private var tokens: [SPICEToken.Located] = []
    private var current = 0
    private var diagnostics: SPICEParserBuffer<ParserDiagnostic>

    // Parse state
    private var components: SPICEParserBuffer<ParsedComponent>
    private var models: SPICEParserBuffer<ParsedModel>
    private var subcircuits: SPICEParserBuffer<ParsedSubcircuit>
    private var analyses: SPICEParserBuffer<ParsedAnalysisCommand>
    private var controls: SPICEParserBuffer<ParsedControlStatement>
    private var parameterDefinitions: SPICEParserBuffer<ParsedParameterDefinition>
    private var parameters: SPICEParserMap<ParsedExpression>
    private var dependencyEvents: SPICEParserBuffer<SPICESourceDependencyEvent>
    private var preprocessingEvents: SPICEParserBuffer<SPICEPreprocessingEvent>
    private var initialConditions: SPICEParserMap<ParsedParameterValue>
    private var nodeSets: SPICEParserMap<ParsedParameterValue>
    private var globalNodes: SPICEParserBuffer<String>
    private var title: String?

    init(
        document: SPICESourceDocument,
        configuration: ParserConfiguration,
        fileResolver: any FileResolver,
        includeDepth: Int = 0,
        conditionalParameterExpressions: [String: String] = [:],
        work: (any SPICESourceWorkAccounting)? = nil,
        resources: (any SPICESourceResourceAccounting)? = nil,
        environment: SPICEPreprocessingEnvironment? = nil,
        contextualResolver: (any SPICEContextualFileResolver)? = nil,
        occurrenceRegistry: SPICEProfileOccurrenceRegistry? = nil
    ) {
        self.document = document
        self.environment = environment
        self.contextualResolver = contextualResolver
        self.occurrenceRegistry = occurrenceRegistry
        self.profileResources = resources
        self.profileStorage = resources.map { SPICEParseStorage(resources: $0) }
        if let resources { self.work = resources } else { self.work = work }
        self.diagnostics = SPICEParserBuffer<ParserDiagnostic>(resources: resources)
        self.components = SPICEParserBuffer<ParsedComponent>(resources: resources)
        self.models = SPICEParserBuffer<ParsedModel>(resources: resources)
        self.subcircuits = SPICEParserBuffer<ParsedSubcircuit>(resources: resources)
        self.analyses = SPICEParserBuffer<ParsedAnalysisCommand>(resources: resources)
        self.controls = SPICEParserBuffer<ParsedControlStatement>(resources: resources)
        self.parameterDefinitions = SPICEParserBuffer<ParsedParameterDefinition>(resources: resources)
        self.parameters = SPICEParserMap<ParsedExpression>(resources: resources)
        self.dependencyEvents = SPICEParserBuffer<SPICESourceDependencyEvent>(resources: resources)
        self.preprocessingEvents = SPICEParserBuffer<SPICEPreprocessingEvent>(resources: resources)
        self.initialConditions = SPICEParserMap<ParsedParameterValue>(resources: resources)
        self.nodeSets = SPICEParserMap<ParsedParameterValue>(resources: resources)
        self.globalNodes = SPICEParserBuffer<String>(resources: resources)
        self.selectedSection = document.librarySection
        self.source = document.text
        self.fileName = document.resolvedPath
        self.captureID = document.captureID
        self.configuration = configuration
        self.fileResolver = fileResolver
        self.includeDepth = includeDepth
        self.conditionalParameterExpressions = conditionalParameterExpressions
    }

    mutating func parse() async throws -> ParseResult {
        try work?.checkCancellation()
        let conditionalResult: SPICEConditionalPreprocessor.Result
        if let profileResources, let environment {
            coordinates = try SPICEPhysicalSourceCoordinates(document: document, resources: profileResources)
            try profileStorage!.hold(document)
            try profileStorage!.hold(environment)
            try profileStorage!.hold(coordinates!)
            conditionalResult = try SPICEConditionalPreprocessor().processOwned(
                document: document, environment: environment, resources: profileResources)
            guard let owned = conditionalResult.storage else { throw SPICEBoundedSourceError.unaccountedSource }
            try profileStorage!.hold(owned.immutableOwner())
        } else {
            try work?.charge(.projectedBytes, units: UInt64(source.utf8.count))
            conditionalResult = try SPICEConditionalPreprocessor().process(source: source, fileName: fileName,
                initialParameters: conditionalParameterExpressions, work: work)
        }
        try preprocessingEvents.append(contentsOf: conditionalResult.events)
        try diagnostics.append(contentsOf: conditionalResult.diagnostics)

        // Tokenize
        var lexer = SPICELexer(
            source: conditionalResult.source,
            fileName: fileName,
            configuration: configuration
        )
        if let profileResources {
            let owned = try lexer.tokenizeOwned(resources: profileResources)
            tokens = owned.tokens
            try profileStorage!.hold(owned.storage.immutableOwner())
        } else { tokens = try lexer.tokenizeChecked(work: work) }
        // Prepay a conservative retained-value allowance before statement/AST allocation.
        try work?.charge(.retainedElements, units: UInt64(tokens.count))

        // The title is free text, not a quoted-value role.
        try parseTitle()
        for token in tokens[current...] {
            try profileResources?.charge(.tokens, units: 1)
            try profileResources?.checkCancellation()
            switch token.token {
            case .unterminatedQuote:
                try diagnostics.append(.error("Unterminated quoted value", at: token.location))
            default:
                break
            }
        }

        // Parse statements
        while !isAtEnd {
            do {
                try await parseStatement()
            } catch {
                if resolverFailed { throw error }
                if work != nil, !(error is ParserDiagnostic) { throw error }
                if let diag = error as? ParserDiagnostic {
                    try diagnostics.append(diag)
                } else {
                    try diagnostics.append(.error((profileResources == nil ? "\(error)" : "Source parsing failed"), at: currentLocation))
                }
                try synchronize()
            }
        }

        let rawComponents = try components.export(storage: &profileStorage)
        let rawModels = try models.export(storage: &profileStorage)
        let rawSubcircuits = try subcircuits.export(storage: &profileStorage)
        let resolvedComponents: [ParsedComponent]
        let resolvedSubcircuits: [ParsedSubcircuit]
        if profileResources != nil {
            var modelNames = SPICEParserMap<Bool>(resources: profileResources)
            for model in rawModels { try modelNames.set(true, for: normalized(model.name)) }
            resolvedComponents = try accountedResistorRoles(in: rawComponents, models: modelNames)
            resolvedSubcircuits = try accountedResistorSubcircuitRoles(rawSubcircuits, inheritedModels: modelNames)
        } else {
            let modelNames = Set(rawModels.map { $0.name.lowercased() })
            resolvedComponents = resistorRoles(in: rawComponents, models: modelNames)
            resolvedSubcircuits = resistorSubcircuitRoles(rawSubcircuits, inheritedModels: modelNames)
        }
        let netlist = ParsedNetlist(title: title, components: resolvedComponents, models: rawModels,
            subcircuits: resolvedSubcircuits, analyses: try analyses.export(storage: &profileStorage),
            controls: try controls.export(storage: &profileStorage),
            parameterDefinitions: try parameterDefinitions.export(storage: &profileStorage),
            parameters: try parameters.export(storage: &profileStorage),
            preprocessingEvents: try preprocessingEvents.export(storage: &profileStorage),
            dependencyEvents: try dependencyEvents.export(storage: &profileStorage),
            initialConditions: try initialConditions.export(storage: &profileStorage),
            nodeSets: try nodeSets.export(storage: &profileStorage),
            globalNodes: try globalNodes.export(storage: &profileStorage), sourcePath: fileName)
        try profileResources?.checkCancellation()
        return ParseResult(netlist: netlist, diagnostics: try diagnostics.export(storage: &profileStorage))
    }

    fileprivate mutating func parseOwned() async throws -> SPICEOwnedParseResult {
        do {
            let result = try await parse()
            for diagnostic in result.diagnostics {
                try profileResources!.checkCancellation()
                try profileResources!.charge(.tokens, units: 1)
                if diagnostic.severity == .error || (configuration.strictMode && diagnostic.severity == .warning) {
                    throw diagnostic
                }
            }
            guard let netlist = result.netlist, let profileStorage else {
                throw SPICEBoundedSourceError.invalidSourceContext
            }
            try profileResources!.checkCancellation()
            let owner = try profileStorage.immutableOwner()
            try profileResources!.checkCancellation()
            return SPICEOwnedParseResult(netlist: netlist, retaining: owner)
        } catch let diagnostic as ParserDiagnostic {
            if resolverFailed { throw diagnostic }
            // Copy the needed diagnostic payload; incomplete AST owners leave with this parser.
            var failureStorage = SPICEParseStorage(resources: profileResources!)
            try failureStorage.hold(document)
            guard diagnostic.fixIts.isEmpty, diagnostic.notes.isEmpty else {
                throw SPICEBoundedSourceError.unsupportedBudgetCapability("Rich grammar failure diagnostics")
            }
            let message = try failureStorage.copyText(diagnostic.message)
            let location = try diagnostic.location.map { value in
                SourceLocation(file: try failureStorage.copyText(value.file), line: value.line, column: value.column)
            }
            let range = try diagnostic.range.map { value in
                SourceRange(start: SourceLocation(file: try failureStorage.copyText(value.start.file),
                    line: value.start.line, column: value.start.column),
                    end: SourceLocation(file: try failureStorage.copyText(value.end.file),
                    line: value.end.line, column: value.end.column))
            }
            let ownedDiagnostic = ParserDiagnostic(severity: diagnostic.severity, message: message,
                location: location, range: range)
            // Throwing stores this value in an Error box; reserve its concrete payload
            // while runtime box headers remain outside the managed extent contract.
            let failurePayload = try SPICESourceCapacity.reserve(of: SPICEProfileParseFailure.self,
                capacity: 1, kind: .liveOwnedBytes, resources: profileResources!)
            try failureStorage.hold(failurePayload)
            throw SPICEProfileParseFailure(diagnostic: ownedDiagnostic, retaining: try failureStorage.immutableOwner())
        }
    }

    // MARK: - Parsing Methods

    private func resistorRoles(in values: [ParsedComponent], models: Set<String>) -> [ParsedComponent] {
        values.map { component in
            guard component.type == .resistor, component.modelName == nil,
                  let candidate = component.passiveModelCandidate,
                  models.contains(candidate.lowercased()) else { return component }
            var parameters = component.parameters
            parameters.removeValue(forKey: "r")
            return ParsedComponent(name: component.name, type: component.type, nodes: component.nodes,
                modelName: candidate, parameters: parameters, location: component.location)
        }
    }

    private func resistorSubcircuitRoles(_ values: [ParsedSubcircuit], inheritedModels: Set<String>) -> [ParsedSubcircuit] {
        values.map { subcircuit in
            let models = inheritedModels.union(subcircuit.body.models.map { $0.name.lowercased() })
            let body = ParsedNetlistBody(components: resistorRoles(in: subcircuit.body.components, models: models),
                models: subcircuit.body.models,
                subcircuits: resistorSubcircuitRoles(subcircuit.body.subcircuits, inheritedModels: models),
                parameters: subcircuit.body.parameters, parameterDefinitions: subcircuit.body.parameterDefinitions)
            return ParsedSubcircuit(name: subcircuit.name, ports: subcircuit.ports,
                parameters: subcircuit.parameters, body: body, location: subcircuit.location, origin: subcircuit.origin)
        }
    }

    private mutating func accountedResistorRoles(in values: [ParsedComponent], models: SPICEParserMap<Bool>) throws -> [ParsedComponent] {
        var output = SPICEParserBuffer<ParsedComponent>(resources: profileResources)
        for component in values {
            try profileResources?.charge(.retainedElements, units: 1)
            try profileResources?.checkCancellation()
            guard component.type == .resistor, component.modelName == nil,
                  let candidate = component.passiveModelCandidate,
                  try models[normalized(candidate)] != nil else {
                try output.append(component); continue
            }
            var parameters = SPICEParserMap<ParsedParameterValue>(resources: profileResources)
            for (name, value) in component.parameters { try parameters.set(value, for: name) }
            try parameters.removeValue(forKey: "r")
            try output.append(ParsedComponent(name: component.name, type: component.type, nodes: component.nodes,
                modelName: candidate, parameters: try parameters.export(storage: &profileStorage), location: component.location))
        }
        return try output.export(storage: &profileStorage)
    }

    private mutating func accountedResistorSubcircuitRoles(_ values: [ParsedSubcircuit], inheritedModels: SPICEParserMap<Bool>) throws -> [ParsedSubcircuit] {
        var output = SPICEParserBuffer<ParsedSubcircuit>(resources: profileResources)
        for subcircuit in values {
            try profileResources?.checkCancellation()
            try profileResources?.charge(.retainedElements, units: 1)
            var models = inheritedModels
            for model in subcircuit.body.models { try models.set(true, for: normalized(model.name)) }
            let body = ParsedNetlistBody(components: try accountedResistorRoles(in: subcircuit.body.components, models: models),
                models: subcircuit.body.models,
                subcircuits: try accountedResistorSubcircuitRoles(subcircuit.body.subcircuits, inheritedModels: models),
                parameters: subcircuit.body.parameters, parameterDefinitions: subcircuit.body.parameterDefinitions)
            try output.append(ParsedSubcircuit(name: subcircuit.name, ports: subcircuit.ports,
                parameters: subcircuit.parameters, body: body, location: subcircuit.location, origin: subcircuit.origin))
        }
        return try output.export(storage: &profileStorage)
    }

    private mutating func parseTitle() throws {
        // In SPICE, the very first line is always the title.
        // If it starts with '*' it was lexed as a .comment token.
        switch currentToken {
        case .comment(let text):
            // Strip leading "* " from comment text
            if profileResources == nil {
                let stripped = text.drop(while: { $0 == "*" || $0 == " " })
                title = String(stripped)
            } else {
                var trimming = true
                var stripped = SPICEParserBuffer<UInt8>(resources: profileResources)
                for byte in text.utf8 {
                    try profileResources?.charge(.lexicalBytes, units: 1)
                    try profileResources?.checkCancellation()
                    guard byte < 128 else { throw SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode title trimming") }
                    if trimming && (byte == 42 || byte == 32) { continue }
                    trimming = false
                    try stripped.append(byte)
                }
                title = try byteString(stripped)
            }
            try advance()
        case .identifier(let text):
            var titleParts = SPICEParserBuffer<String>(resources: profileResources)
            try titleParts.append(text)
            try advance()
            while !isAtEnd && !isNewline {
                if case .identifier(let more) = currentToken {
                    try titleParts.append(more)
                } else if case .number(let n) = currentToken {
                    try titleParts.append(try doubleText(n))
                }
                try advance()
            }
            title = try joined(titleParts, separator: " ")
        default:
            break
        }
        // Skip trailing newlines/comments after the title line
        try skipNewlinesAndComments()
    }

    private mutating func parseStatement() async throws {
        try work?.checkCancellation()
        try skipNewlinesAndComments()
        guard !isAtEnd else { return }
        try work?.charge(.retainedElements, units: 1)
        try beginStatement()

        switch currentToken {
        case .directive(let name):
            try await parseDirective(name)

        case .identifier(let name):
            try parseComponent(name: name)

        case .comment:
            try advance()

        case .newline, .continuation:
            try advance()

        default:
            try advance()
        }
    }

    private mutating func beginStatement() throws {
        guard profileResources != nil else { return }
        activeStatementOrdinal = nextStatementOrdinal
        let (next, overflow) = nextStatementOrdinal.addingReportingOverflow(1)
        guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
        nextStatementOrdinal = next
    }

    private mutating func parseDirective(_ name: String) async throws {
        let loc = currentLocation
        try advance() // skip directive

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
            try skipToEndOfLine()
        case "end":
            try skipToEndOfLine()
        case "ends":
            try skipToEndOfLine()
        case "tran":
            try parseTransientAnalysis(location: loc)
        case "ac":
            try parseACAnalysis(location: loc)
        case "dc":
            try parseDCAnalysis(location: loc)
        case "op":
            try analyses.append(.op)
            try skipToEndOfLine()
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
            throw ParserDiagnostic.error((profileResources == nil ? "Unsupported SPICE directive: .\(name)" : "Unsupported SPICE directive: ."), at: loc)
        }
    }

    private mutating func parseAlter(location: SourceLocation?) throws {
        guard case .identifier(let target) = currentToken else {
            throw ParserDiagnostic.error("Expected alter target", at: currentLocation)
        }
        try advance()
        guard case .identifier(let parameter) = currentToken else {
            throw ParserDiagnostic.error("Expected altered parameter name", at: currentLocation)
        }
        try advance()
        if case .equals = currentToken {
            try advance()
        }
        guard let value = try parseParameterValueIfPresent() else {
            throw ParserDiagnostic.error("Expected altered parameter value", at: currentLocation)
        }
        try controls.append(.alter(AlterSpec(
            target: target,
            parameter: parameter,
            value: value,
            location: location
        )))
        try skipToEndOfLine()
    }

    private mutating func parseHDL(location: SourceLocation?) throws {
        let path = try parseTextPath()
        try controls.append(.hdl(path: path, location: location))
        try skipToEndOfLine()
    }

    private mutating func parseComponent(name: String) throws {
        let loc = currentLocation
        try advance() // skip name

        try checkASCIIText(name, capability: "Cooperative Unicode component prefix")
        guard let firstChar = name.first else {
            throw ParserDiagnostic.error("Empty component name", at: loc)
        }

        guard let type = ComponentType(prefix: firstChar) else {
            throw ParserDiagnostic.error((profileResources == nil ? "Unknown component type: \(firstChar)" : "Unknown component type: "), at: loc)
        }

        var nodes = SPICEParserBuffer<ParsedNodeRef>(resources: profileResources)
        var modelName: String?
        var passiveModelCandidate: String?
        var params = SPICEParserMap<ParsedParameterValue>(resources: profileResources)

        // Parse nodes
        let nodeCount = type.standardNodeCount ?? 2

        // For subcircuit instances, collect all node tokens until the parameter
        // section; the final identifier is the subcircuit name. Node names may be
        // numeric (e.g. ground "0"), so numbers are collected as nodes too.
        if type == .subcircuitInstance {
            var tokens = SPICEParserBuffer<String>(resources: profileResources)
            while try !isAtEnd && !isNewline && !currentParameterStart() {
                if case .identifier(let id) = currentToken {
                    try tokens.append(id)
                    try advance()
                } else if case .number(let n) = currentToken {
                    try tokens.append(try integerText(n))
                    try advance()
                } else if case .invalidNumericLiteral(let text) = currentToken {
                    throw ParserDiagnostic.error((profileResources == nil ? "Invalid numeric literal '\(text)'" : "Invalid numeric literal ''"), at: currentLocation)
                } else if case .invalidNumericSuffix(let suffix) = currentToken {
                    throw ParserDiagnostic.error((profileResources == nil ? "Unknown numeric suffix '\(suffix)'" : "Unknown numeric suffix ''"), at: currentLocation)
                } else {
                    break
                }
            }
            // The last token is the subcircuit name; the rest are connection nodes.
            if let subcktName = tokens.last {
                modelName = subcktName
            }
            for index in 0..<max(0, tokens.count - 1) {
                try nodes.append(ParsedNodeRef(name: tokens[index], location: loc))
            }
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
                    try nodes.append(ParsedNodeRef(name: nodeName, location: currentLocation))
                    try advance()
                } else if case .number(let n) = currentToken {
                    try nodes.append(ParsedNodeRef(name: try integerText(n), location: currentLocation))
                    try advance()
                } else if case .invalidNumericLiteral(let text) = currentToken {
                    throw ParserDiagnostic.error((profileResources == nil ? "Invalid numeric literal '\(text)'" : "Invalid numeric literal ''"), at: currentLocation)
                } else if case .invalidNumericSuffix(let suffix) = currentToken {
                    throw ParserDiagnostic.error((profileResources == nil ? "Unknown numeric suffix '\(suffix)'" : "Unknown numeric suffix ''"), at: currentLocation)
                }
            }

            // For model-backed devices, parse model name
            if type == .mosfet || type == .bjt || type == .jfet || type == .mesfet
                || type == .diode || type == .uniformRC
                || type == .switch_ || type == .currentSwitch {
                if case .identifier(let model) = currentToken {
                    modelName = model
                    try advance()
                }
            }
        }

        if type == .capacitor {
            try parseCapacitorParameters(modelName: &modelName, candidate: &passiveModelCandidate, params: &params)
        }

        // Parse parameters
        while type != .capacitor && !isAtEnd && !isNewline {
            if type == .resistor, modelName == nil,
               let candidate = passiveModelCandidate {
                switch currentToken {
                case .number, .leftBrace, .quotedExpression, .plus, .minus:
                    modelName = candidate
                    passiveModelCandidate = nil
                    try params.removeValue(forKey: "r")
                default: break
                }
            }
            if case .dottedLiteral(let text) = currentToken {
                throw ParserDiagnostic.error((profileResources == nil ? "Version literal '\(text)' is not a numerical component value" : "Version literal '' is not a numerical component value"), at: currentLocation)
            }
            if case .identifier(let paramName) = currentToken {
                let lower = try normalized(paramName)
                try advance()
                if case .equals = currentToken {
                    try advance()
                    if type == .resistor, lower == "r" || lower == "resistance",
                       let candidate = passiveModelCandidate, modelName == nil {
                        modelName = candidate
                        passiveModelCandidate = nil
                        try params.removeValue(forKey: "r")
                    }
                    if type == .mosfet && lower == "ic" {
                        let keys = try fixedStrings(count: 3) { ["ic_vds", "ic_vgs", "ic_vbs"] }
                        for key in keys { try params.set(.numeric(0), for: key) }
                        for index in 0..<3 {
                            try params.set(try parseParameterValue(), for: keys[index])
                            guard case .comma = currentToken else { break }
                            if index == 2 {
                                throw ParserDiagnostic.error("MOS IC requires one to three values", at: currentLocation)
                            }
                            try advance()
                        }
                    } else {
                        let value = type == .resistor && (lower == "r" || lower == "resistance")
                            ? try parseNamedPassiveValue()
                            : try parseParameterValue()
                        try params.set(value, for: lower)
                    }
                } else if type == .mosfet && lower == "off" {
                    try params.set(.boolean(true), for: lower)
                } else if (type == .voltageSource || type == .currentSource),
                          lower == "dc" || lower == "ac" {
                    // SPICE source syntax: V1 n1 n2 dc <value> ac <value>
                    // "dc <value>" sets the DC voltage/current
                    // "ac <value>" sets the AC magnitude
                    // Current sources carry their DC value under "i"; voltage sources under "v".
                    let dcKey = (type == .currentSource) ? "i" : "v"
                    if let value = try parseSignedNumber() {
                        try params.set(.numeric(value), for: lower == "dc" ? dcKey : "ac")
                    } else {
                        throw ParserDiagnostic.error("DC/AC source value must be numeric", at: currentLocation)
                    }
                } else if (type == .voltageSource || type == .currentSource),
                          lower == "pulse" {
                    // PULSE(v1 v2 td tr tf pw per)
                    try parseSourcePulse(into: &params, current: type == .currentSource)
                } else if (type == .voltageSource || type == .currentSource),
                          lower == "sin" || lower == "sine" {
                    // SIN(vo va freq td theta)
                    try parseSourceSine(into: &params, current: type == .currentSource)
                } else if (type == .voltageSource || type == .currentSource), lower == "pwl" {
                    try params.set(.numericVector(try parseSourceVector()), for: "pwl")
                } else {
                    // Positional value (like resistance value for R, or gain for E)
                    if let key = try positionalKey(for: type, existing: params) {
                        if let value = try parseNumberFromIdentifier(paramName) {
                            try params.set(.numeric(value), for: key)
                        } else {
                            try params.set(.expression(try identifierExpression(paramName)), for: key)
                            if type == .resistor { passiveModelCandidate = paramName }
                        }
                    } else if type == .voltageSource || type == .currentSource {
                        throw ParserDiagnostic.error((profileResources == nil ? "Unsupported source waveform or parameter '\(paramName)'" : "Unsupported source waveform or parameter ''"), at: currentLocation)
                    } else if type == .resistor {
                        guard modelName == nil, (try params["r"]) != nil else {
                            throw ParserDiagnostic.error((profileResources == nil ? "Unexpected resistor token '\(paramName)'" : "Unexpected resistor token ''"), at: currentLocation)
                        }
                        modelName = paramName
                        passiveModelCandidate = nil
                    }
                }
            } else if case .quotedExpression = currentToken {
                if (type == .voltageSource || type == .currentSource), !params.isEmpty {
                    throw ParserDiagnostic.error("Unexpected extra numeric source value", at: currentLocation)
                }
                guard let key = try positionalKey(for: type, existing: params) else {
                    throw ParserDiagnostic.error("Unexpected quoted positional value", at: currentLocation)
                }
                try params.set(try parseParameterValue(), for: key)
            } else if case .string = currentToken {
                throw ParserDiagnostic.error("Opaque string is not a numeric positional value", at: currentLocation)
            } else if case .number(let n) = currentToken {
                // Positional value (resistance for R, DC value for a source, etc.)
                if (type == .voltageSource || type == .currentSource), !params.isEmpty {
                    throw ParserDiagnostic.error("Unexpected extra numeric source value", at: currentLocation)
                }
                if let key = try positionalKey(for: type, existing: params) {
                    try params.set(.numeric(n), for: key)
                } else if type == .resistor {
                    throw ParserDiagnostic.error("Unexpected extra resistor value", at: currentLocation)
                }
                try advance()
            } else if case .invalidNumericLiteral(let text) = currentToken {
                throw ParserDiagnostic.error((profileResources == nil ? "Invalid numeric literal '\(text)'" : "Invalid numeric literal ''"), at: currentLocation)
            } else if case .invalidNumericSuffix(let suffix) = currentToken {
                throw ParserDiagnostic.error((profileResources == nil ? "Unknown numeric suffix '\(suffix)'" : "Unknown numeric suffix ''"), at: currentLocation)
            } else if isSignToken(currentToken) {
                // Signed positional value, e.g. a negative source DC value (V1 n1 n2 -2).
                if let value = try parseSignedNumber(), let key = try positionalKey(for: type, existing: params) {
                    try params.set(.numeric(value), for: key)
                } else if type == .resistor {
                    throw ParserDiagnostic.error("Unexpected signed resistor value", at: currentLocation)
                }
            } else if case .leftBrace = currentToken {
                if let key = try positionalKey(for: type, existing: params) {
                    try params.set(try parseExpressionValue(), for: key)
                } else {
                    if type == .resistor {
                        throw ParserDiagnostic.error("Unexpected extra resistor expression", at: currentLocation)
                    }
                    _ = try parseExpressionValue()
                }
            } else {
                if type == .voltageSource || type == .currentSource {
                    throw ParserDiagnostic.error("Unexpected source token", at: currentLocation)
                }
                if type == .resistor {
                    throw ParserDiagnostic.error("Unexpected resistor token", at: currentLocation)
                }
                try advance()
            }
        }

        if type == .resistor, try nodes.count != 2 || (params["r"] == nil && params["resistance"] == nil && modelName == nil) {
            throw ParserDiagnostic.error("Resistor requires two nodes and resistance or model", at: loc)
        }
        if type == .capacitor, try nodes.count != 2 || (params["c"] == nil && params["q"] == nil && modelName == nil) {
            throw ParserDiagnostic.error("Capacitor requires two nodes and capacitance, charge expression or model", at: loc)
        }
        try components.append(ParsedComponent(
            name: name,
            type: type,
            nodes: try nodes.export(storage: &profileStorage),
            modelName: modelName,
            passiveModelCandidate: passiveModelCandidate,
            parameters: try params.export(storage: &profileStorage),
            location: loc
        ))
    }

    private mutating func parseCapacitorParameters(
        modelName: inout String?,
        candidate: inout String?,
        params: inout SPICEParserMap<ParsedParameterValue>
    ) throws {
        var hasNamedCapacitance = false
        var hasPostModelValue = false
        while !isAtEnd && !isNewline {
            if case .identifier(let name) = currentToken {
                let location = currentLocation
                let lower = try normalized(name)
                try advance()
                if case .equals = currentToken {
                    try advance()
                    if lower == "q" {
                        guard params.isEmpty, modelName == nil, candidate == nil else {
                            throw unsupportedMixedChargeCapacitor(at: location)
                        }
                        let value = try parseNamedPassiveValue()
                        guard case .expression = value else {
                            throw ParserDiagnostic.error("Numeric charge requires quotes or braces", at: location)
                        }
                        try params.set(value, for: lower)
                        guard isAtEnd || isNewline else {
                            if case .identifier(let next) = currentToken, try normalized(next) == "q",
                               current + 1 < tokens.count, tokens[current + 1].token == .equals {
                                throw ParserDiagnostic.error("Duplicate capacitor charge expression", at: currentLocation)
                            }
                            throw unsupportedMixedChargeCapacitor(at: currentLocation)
                        }
                    } else if lower == "c" {
                        if let symbol = candidate {
                            modelName = symbol
                            candidate = nil
                            try params.removeValue(forKey: "c")
                        }
                        try params.set(try parseNamedPassiveValue(), for: lower)
                        hasNamedCapacitance = true
                    } else {
                        try params.set(try parseParameterValue(), for: lower)
                    }
                } else {
                    guard !hasNamedCapacitance, modelName == nil, candidate == nil else {
                        throw ParserDiagnostic.error("Unexpected capacitor model or positional token", at: location)
                    }
                    if try params["c"] == nil {
                        if let value = try parseNumberFromIdentifier(name) {
                            try params.set(.numeric(value), for: "c")
                        } else {
                            // Preserve ambiguity until lowering can see the complete parameter scope.
                            candidate = name
                            try params.set(.expression(try identifierExpression(name)), for: "c")
                        }
                    } else {
                        modelName = name
                    }
                }
                continue
            }
            switch currentToken {
            case .number, .plus, .minus, .leftBrace, .quotedExpression:
                if let symbol = candidate {
                    modelName = symbol
                    candidate = nil
                    try params.removeValue(forKey: "c")
                }
                guard !hasNamedCapacitance, !hasPostModelValue,
                      try modelName != nil || params["c"] == nil else {
                    throw ParserDiagnostic.error("Unexpected extra capacitor value", at: currentLocation)
                }
                try params.set(try parseParameterValue(), for: "c")
                if modelName != nil { hasPostModelValue = true }
            default:
                throw ParserDiagnostic.error("Unexpected capacitor token", at: currentLocation)
            }
        }
    }

    // FIXME(INCOMPLETE_IMPLEMENTATION): Mixed charge/capacitance/model/attribute source forms are unsupported.
    // Ordinary and bounded public SPICE parsing reach this source-profile refusal.
    // Admit these forms only after ordered source roles preserve the verified frontend selection semantics.
    private func unsupportedMixedChargeCapacitor(at location: SourceLocation?) -> ParserDiagnostic {
        .error("Mixed capacitor charge/value/model/attribute source forms are not implemented", at: location)
    }

    private mutating func parseCurrentControlledSourceComponent(
        type: ComponentType,
        nodes: inout SPICEParserBuffer<ParsedNodeRef>,
        params: inout SPICEParserMap<ParsedParameterValue>
    ) throws {
        try nodes.append(try parseRequiredNodeRef())
        try nodes.append(try parseRequiredNodeRef())

        let controlLocation = currentLocation
        if case .number = currentToken {
            try nodes.append(try parseRequiredNodeRef())
            try nodes.append(try parseRequiredNodeRef())
            let gainKey = type == .cccs ? "f" : "h"
            try parseControlledGainParameter(into: &params, key: gainKey)
            return
        }
        guard case .identifier(let controlName) = currentToken else {
            throw ParserDiagnostic.error("Expected controlling source or sense node", at: currentLocation)
        }
        try advance()

        let gainKey = type == .cccs ? "f" : "h"
        if try currentControlledElementUsesExplicitSenseTerminals() {
            try nodes.append(ParsedNodeRef(name: controlName, location: controlLocation))
            try nodes.append(try parseRequiredNodeRef())
        } else {
            try params.set(.string(controlName), for: "control_source")
        }
        try parseControlledGainParameter(into: &params, key: gainKey)
    }

    private mutating func parseCurrentControlledSwitchComponent(
        nodes: inout SPICEParserBuffer<ParsedNodeRef>,
        modelName: inout String?,
        params: inout SPICEParserMap<ParsedParameterValue>
    ) throws {
        try nodes.append(try parseRequiredNodeRef())
        try nodes.append(try parseRequiredNodeRef())

        let controlLocation = currentLocation
        if case .number = currentToken {
            try nodes.append(try parseRequiredNodeRef())
            try nodes.append(try parseRequiredNodeRef())
            modelName = try parseRequiredIdentifier(message: "Expected current switch model name")
            return
        }
        guard case .identifier(let controlName) = currentToken else {
            throw ParserDiagnostic.error("Expected controlling source or sense node", at: currentLocation)
        }
        try advance()

        if try currentControlledElementUsesExplicitSenseTerminals() {
            try nodes.append(ParsedNodeRef(name: controlName, location: controlLocation))
            try nodes.append(try parseRequiredNodeRef())
        } else {
            try params.set(.string(controlName), for: "control_source")
        }

        modelName = try parseRequiredIdentifier(message: "Expected current switch model name")
    }

    private mutating func parseRequiredNodeRef() throws -> ParsedNodeRef {
        let location = currentLocation
        if case .identifier(let nodeName) = currentToken {
            try advance()
            return ParsedNodeRef(name: nodeName, location: location)
        }
        if case .number(let n) = currentToken {
            try advance()
            return ParsedNodeRef(name: try integerText(n), location: location)
        }
        if case .invalidNumericLiteral(let text) = currentToken {
            throw ParserDiagnostic.error((profileResources == nil ? "Invalid numeric literal '\(text)'" : "Invalid numeric literal ''"), at: currentLocation)
        }
        if case .invalidNumericSuffix(let suffix) = currentToken {
            throw ParserDiagnostic.error((profileResources == nil ? "Unknown numeric suffix '\(suffix)'" : "Unknown numeric suffix ''"), at: currentLocation)
        }
        throw ParserDiagnostic.error("Expected node name", at: currentLocation)
    }

    private mutating func parseRequiredIdentifier(message: String) throws -> String {
        guard case .identifier(let value) = currentToken else {
            throw ParserDiagnostic.error(message, at: currentLocation)
        }
        try advance()
        return value
    }

    private mutating func parseControlledGainParameter(
        into params: inout SPICEParserMap<ParsedParameterValue>,
        key: String
    ) throws {
        if case .identifier(let parameterName) = currentToken,
           try normalized(parameterName) == key,
           current + 1 < tokens.count,
           case .equals = tokens[current + 1].token {
            try advance()
            try advance()
            try params.set(try parseParameterValue(), for: key)
            return
        }
        try params.set(try parseParameterValue(), for: key)
    }

    /// Reads an optional leading +/- sign followed by a numeric token and
    /// returns the signed value. The lexer emits a separate `.minus`/`.plus`
    /// token before a number, so source values and positional component values
    /// (which are not expressions) must reassemble the sign here.
    private mutating func parseSignedNumber() throws -> Double? {
        var sign = 1.0
        if case .minus = currentToken {
            sign = -1.0
            try advance()
        } else if case .plus = currentToken {
            try advance()
        }
        if case .number(let n) = currentToken {
            try advance()
            return sign * n
        }
        if case .invalidNumericLiteral(let text) = currentToken {
            throw ParserDiagnostic.error((profileResources == nil ? "Invalid numeric literal '\(text)'" : "Invalid numeric literal ''"), at: currentLocation)
        }
        if case .invalidNumericSuffix(let suffix) = currentToken {
            throw ParserDiagnostic.error((profileResources == nil ? "Unknown numeric suffix '\(suffix)'" : "Unknown numeric suffix ''"), at: currentLocation)
        }
        if case .identifier(let s) = currentToken, let n = try parseNumberFromIdentifier(s) {
            try advance()
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
    private func positionalKey(for type: ComponentType, existing params: SPICEParserMap<ParsedParameterValue>) throws -> String? {
        switch type {
        case .resistor: return (try params["r"]) == nil ? "r" : nil
        case .capacitor: return (try params["c"]) == nil ? "c" : nil
        case .inductor: return (try params["l"]) == nil ? "l" : nil
        case .voltageSource: return (try params["v"]) == nil ? "v" : nil
        case .currentSource: return (try params["i"]) == nil ? "i" : nil
        case .vcvs: return (try params["e"]) == nil ? "e" : nil
        case .vccs: return (try params["g"]) == nil ? "g" : nil
        case .cccs: return (try params["f"]) == nil ? "f" : nil
        case .ccvs: return (try params["h"]) == nil ? "h" : nil
        case .coupledInductors: return (try params["k"]) == nil ? "k" : nil
        default: return nil
        }
    }

    private mutating func parseNumberFromIdentifier(_ str: String) throws -> Double? {
        // Try to parse identifiers like "1k", "10u", etc.
        let numStr: String
        let suffixStr: String
        if profileResources == nil {
            var number = ""
            var suffix = ""
            var inSuffix = false
            for character in str {
                if !inSuffix && (character.isNumber || character == ".") { number.append(character) }
                else { inSuffix = true; suffix.append(character) }
            }
            numStr = number
            suffixStr = suffix
        } else {
            var number = SPICEParserBuffer<UInt8>(resources: profileResources)
            var suffix = SPICEParserBuffer<UInt8>(resources: profileResources)
            var inSuffix = false
            for byte in str.utf8 {
                try profileResources?.charge(.lexicalBytes, units: 1)
                try profileResources?.checkCancellation()
                guard byte < 128 else { throw SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode numeric conversion") }
                if !inSuffix && ((byte >= 48 && byte <= 57) || byte == 46) { try number.append(byte) }
                else { inSuffix = true; try suffix.append(byte) }
            }
            numStr = try byteString(number)
            suffixStr = try byteString(suffix)
        }
        guard let base = Double(numStr), base.isFinite else { return nil }

        let scale: Double
        switch try normalized(suffixStr) {
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
            try advance()
            return value
        case .invalidNumericLiteral(let text):
            throw ParserDiagnostic.error((profileResources == nil ? "Invalid numeric literal '\(text)'" : "Invalid numeric literal ''"), at: currentLocation)
        case .invalidNumericSuffix(let suffix):
            throw ParserDiagnostic.error((profileResources == nil ? "Unknown numeric suffix '\(suffix)'" : "Unknown numeric suffix ''"), at: currentLocation)
        case .identifier(let text):
            guard let value = try parseNumberFromIdentifier(text) else {
                return nil
            }
            try advance()
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
            throw ParserDiagnostic.error((profileResources == nil ? "Expected positive integer \(label)" : "Expected positive integer "), at: location)
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
            throw ParserDiagnostic.error((profileResources == nil ? "Expected nonnegative integer \(label)" : "Expected nonnegative integer "), at: location)
        }
        return Int(value)
    }

    private mutating func parseParameterValueIfPresent() throws -> ParsedParameterValue? {
        if isAtEnd || isNewline {
            return nil
        }

        switch currentToken {
        case .number, .invalidNumericLiteral, .invalidNumericSuffix,
             .identifier, .string, .quotedExpression, .unterminatedQuote,
             .invalidCharacter, .leftBrace, .minus, .plus:
            return try parseParameterValue()
        default:
            return nil
        }
    }

    private mutating func parseSourceVector() throws -> [Double] {
        guard case .leftParen = currentToken else {
            throw ParserDiagnostic.error("Source waveform requires parentheses", at: currentLocation)
        }
        try advance()
        var values = SPICEParserBuffer<Double>(resources: profileResources)
        while !isAtEnd && !isNewline {
            if case .rightParen = currentToken { try advance(); return try values.export(storage: &profileStorage) }
            if case .comma = currentToken { try advance(); continue }
            guard let value = try parseSignedNumericTokenIfPresent(), value.isFinite else {
                throw ParserDiagnostic.error("Source waveform requires finite numeric values", at: currentLocation)
            }
            try values.append(value)
        }
        throw ParserDiagnostic.error("Unterminated source waveform", at: currentLocation)
    }

    private mutating func parseSourcePulse(into params: inout SPICEParserMap<ParsedParameterValue>, current: Bool) throws {
        let values = try parseSourceVector()
        let keys = try fixedStrings(count: 7) { current ? ["i1", "i2", "td", "tr", "tf", "pw", "per"] : ["v1", "v2", "td", "tr", "tf", "pw", "per"] }
        guard values.count == keys.count else {
            throw ParserDiagnostic.error("PULSE requires seven numeric values", at: currentLocation)
        }
        for (key, value) in zip(keys, values) { try params.set(.numeric(value), for: key) }
    }

    private mutating func parseSourceSine(into params: inout SPICEParserMap<ParsedParameterValue>, current: Bool) throws {
        let values = try parseSourceVector()
        let keys = try fixedStrings(count: 5) { current ? ["io", "ia", "freq", "td", "phase"] : ["vo", "va", "freq", "td", "phase"] }
        guard (3...5).contains(values.count) else {
            throw ParserDiagnostic.error("SIN requires three to five numeric values", at: currentLocation)
        }
        for (key, value) in zip(keys, values) { try params.set(.numeric(value), for: key) }
    }

    private mutating func parseSignedNumericTokenIfPresent() throws -> Double? {
        let sign: Double
        if case .minus = currentToken {
            sign = -1
            try advance()
        } else if case .plus = currentToken {
            sign = 1
            try advance()
        } else {
            sign = 1
        }
        guard let value = try parseNumericTokenIfPresent() else {
            if sign != 1 {
                throw ParserDiagnostic.error(
                    "Expected numeric waveform parameter after sign",
                    at: currentLocation
                )
            }
            return nil
        }
        return sign * value
    }

    private mutating func parseNamedPassiveValue() throws -> ParsedParameterValue {
        switch currentToken {
        case .leftBrace, .quotedExpression:
            return try parseParameterValue()
        default:
            break
        }
        // Parse the original accounted token stream so continuation locations survive.
        let expression = try parseExpression()
        let nextAssignment: Bool
        if case .identifier = currentToken, current + 1 < tokens.count {
            nextAssignment = tokens[current + 1].token == .equals
        } else {
            nextAssignment = false
        }
        guard isAtEnd || isNewline || nextAssignment else {
            throw ParserDiagnostic.error("Unexpected token after named passive expression", at: currentLocation)
        }
        switch expression {
        case .literal(let value): return .numeric(value)
        case .unaryOperation(.negate, .literal(let value)): return .numeric(-value)
        case .unaryOperation(.plus, .literal(let value)): return .numeric(value)
        default: return .expression(expression)
        }
    }

    private mutating func parseParameterValue() throws -> ParsedParameterValue {
        // Handle unary minus/plus before a number (e.g. vto=-0.7)
        if case .minus = currentToken {
            try advance()
            switch currentToken {
            case .number(let n):
                try advance()
                return .numeric(-n)
            case .invalidNumericLiteral(let text):
                throw ParserDiagnostic.error((profileResources == nil ? "Invalid numeric literal '\(text)'" : "Invalid numeric literal ''"), at: currentLocation)
            case .invalidNumericSuffix(let suffix):
                throw ParserDiagnostic.error((profileResources == nil ? "Unknown numeric suffix '\(suffix)'" : "Unknown numeric suffix ''"), at: currentLocation)
            case .identifier(let id):
                try advance()
                if let n = try parseNumberFromIdentifier(id) {
                    return .numeric(-n)
                }
                return .expression(try negatedIdentifierExpression(id))
            default:
                throw ParserDiagnostic.error("Expected number after '-'", at: currentLocation)
            }
        }
        if case .plus = currentToken {
            try advance()
            // Unary plus is a no-op; parse the next value
            return try parseParameterValue()
        }

        switch currentToken {
        case .number(let n):
            try advance()
            return .numeric(n)
        case .invalidNumericLiteral(let text):
            throw ParserDiagnostic.error((profileResources == nil ? "Invalid numeric literal '\(text)'" : "Invalid numeric literal ''"), at: currentLocation)
        case .invalidNumericSuffix(let suffix):
            throw ParserDiagnostic.error((profileResources == nil ? "Unknown numeric suffix '\(suffix)'" : "Unknown numeric suffix ''"), at: currentLocation)
        case .identifier(let id):
            if current + 1 < tokens.count, case .leftParen = tokens[current + 1].token {
                return .expression(try parseExpression())
            }
            try advance()
            // Check if it's a number with suffix
            if let n = try parseNumberFromIdentifier(id) {
                return .numeric(n)
            }
            // It's an expression reference
            return .expression(try identifierExpression(id))
        case .string(let s):
            try advance()
            return .string(s)
        case .quotedExpression:
            return .expression(try parseExpression())
        case .unterminatedQuote:
            throw ParserDiagnostic.error("Unterminated quoted value", at: currentLocation)
        case .invalidCharacter(let character):
            throw ParserDiagnostic.error((profileResources == nil ? "Invalid character '\(character)'" : "Invalid character ''"), at: currentLocation)
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
        try advance()

        let expr = try parseExpression()

        guard case .rightBrace = currentToken else {
            throw ParserDiagnostic.error("Expected '}'", at: currentLocation)
        }
        try advance()

        return .expression(expr)
    }

    private mutating func parseExpression() throws -> ParsedExpression {
        var expressionParser = SPICEExpressionTokenParser(tokens: tokens, currentIndex: current, work: work)
        let expression: ParsedExpression
        if profileStorage != nil { expression = try expressionParser.parseExpression(storage: &profileStorage!) }
        else { expression = try expressionParser.parseExpression() }
        current = expressionParser.currentIndex
        return expression
    }

    private mutating func parseSubcircuit(location: SourceLocation?) async throws {
        let declarationOrdinal = activeStatementOrdinal
        let declarationOffset = try originalStatementOffset(location)
        guard case .identifier(let name) = currentToken else {
            throw ParserDiagnostic.error("Expected subcircuit name", at: currentLocation)
        }
        try advance()

        // Parse ports
        var ports = SPICEParserBuffer<String>(resources: profileResources)
        while try !isAtEnd && !isNewline && !currentParameterStart() {
            if case .identifier(let port) = currentToken {
                try ports.append(port)
                try advance()
            } else if case .number(let n) = currentToken {
                try ports.append(try integerText(n))
                try advance()
            } else if case .invalidNumericLiteral(let text) = currentToken {
                throw ParserDiagnostic.error((profileResources == nil ? "Invalid numeric literal '\(text)'" : "Invalid numeric literal ''"), at: currentLocation)
            } else if case .invalidNumericSuffix(let suffix) = currentToken {
                throw ParserDiagnostic.error((profileResources == nil ? "Unknown numeric suffix '\(suffix)'" : "Unknown numeric suffix ''"), at: currentLocation)
            } else {
                break
            }
        }

        // Parse parameters
        var params = SPICEParserMap<ParsedParameterValue>(resources: profileResources)
        if case .identifier(let id) = currentToken, try isParamsKeyword(id) {
            try advance()
            if case .colon = currentToken { try advance() }
        }
        while !isAtEnd && !isNewline {
            guard case .identifier(let pname) = currentToken else {
                throw ParserDiagnostic.error("Expected subcircuit parameter name", at: currentLocation)
            }
            try advance()
            guard case .equals = currentToken else {
                throw ParserDiagnostic.error("Expected '=' after subcircuit parameter name", at: currentLocation)
            }
            try advance()
            try params.set(try parseParameterValue(), for: pname)
        }

        try skipNewlinesAndComments()

        // Parse subcircuit body
        var bodyComponents = SPICEParserBuffer<ParsedComponent>(resources: profileResources)
        var bodyModels = SPICEParserBuffer<ParsedModel>(resources: profileResources)
        var bodySubcircuits = SPICEParserBuffer<ParsedSubcircuit>(resources: profileResources)
        var bodyParams = SPICEParserMap<ParsedExpression>(resources: profileResources)
        var bodyParameterDefinitions = SPICEParserBuffer<ParsedParameterDefinition>(resources: profileResources)

        // Save current state
        let savedComponents = components
        let savedModels = models
        let savedSubcircuits = subcircuits
        let savedParams = parameters
        let savedParameterDefinitions = parameterDefinitions

        components = SPICEParserBuffer<ParsedComponent>(resources: profileResources)
        models = SPICEParserBuffer<ParsedModel>(resources: profileResources)
        subcircuits = SPICEParserBuffer<ParsedSubcircuit>(resources: profileResources)
        parameters = SPICEParserMap<ParsedExpression>(resources: profileResources)
        parameterDefinitions = SPICEParserBuffer<ParsedParameterDefinition>(resources: profileResources)

        // Parse until .ends. Skip leading newlines/comments before the .ends
        // check, otherwise parseStatement (which skips them itself) would consume
        // the .ends directive and the loop would swallow the rest of the file.
        while !isAtEnd {
            try skipNewlinesAndComments()
            if isAtEnd { break }
            if case .directive(let dir) = currentToken, dir == "ends" {
                try beginStatement()
                try advance()
                try skipToEndOfLine()
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
            components: try bodyComponents.export(storage: &profileStorage),
            models: try bodyModels.export(storage: &profileStorage),
            subcircuits: try bodySubcircuits.export(storage: &profileStorage),
            parameters: try bodyParams.export(storage: &profileStorage),
            parameterDefinitions: try bodyParameterDefinitions.export(storage: &profileStorage)
        )

        try subcircuits.append(ParsedSubcircuit(
            name: name,
            ports: try ports.export(storage: &profileStorage),
            parameters: try params.export(storage: &profileStorage),
            body: body,
            location: location,
            origin: subcircuitOrigin(location, offset: declarationOffset, statementOrdinal: declarationOrdinal)
        ))
    }

    private mutating func parseModel(location: SourceLocation?) throws {
        guard case .identifier(let name) = currentToken else {
            throw ParserDiagnostic.error("Expected model name", at: currentLocation)
        }
        try advance()

        guard case .identifier(let typeStr) = currentToken else {
            throw ParserDiagnostic.error("Expected model type", at: currentLocation)
        }
        try advance()

        guard let type = ModelType(rawValue: try normalized(typeStr, uppercase: true)) else {
            throw ParserDiagnostic.error((profileResources == nil ? "Unknown model type: \(typeStr)" : "Unknown model type: "), at: currentLocation)
        }

        var level: Int?
        var params = SPICEParserMap<ParsedParameterValue>(resources: profileResources)

        // Skip optional parenthesis
        if case .leftParen = currentToken {
            try advance()
        }

        while !isAtEnd && !isNewline {
            if case .rightParen = currentToken {
                try advance()
                break
            }
            if case .identifier(let pname) = currentToken {
                try advance()
                if case .equals = currentToken {
                    try advance()
                    let valueLocation = currentLocation
                    let value: ParsedParameterValue
                    if try normalized(pname) == "version" {
                        switch currentToken {
                        case .dottedLiteral(let text), .string(let text), .identifier(let text):
                            value = .string(text)
                            try advance()
                        case .quotedExpression(let text):
                            value = .string(try decodedQuotedText(text))
                            try advance()
                        case .number(let number):
                            value = .string(try doubleText(number))
                            try advance()
                        default:
                            throw ParserDiagnostic.error("Expected exact model version", at: currentLocation)
                        }
                    } else {
                        value = try parseParameterValue()
                    }
                    if try normalized(pname) == "level" {
                        let number: Double
                        switch value {
                        case .numeric(let value), .expression(.literal(let value)):
                            number = value
                        default:
                            throw ParserDiagnostic.error("Model level must be a constant integer literal", at: valueLocation)
                        }
                        guard let parsedLevel = Int(exactly: number) else {
                            throw ParserDiagnostic.error("Model level must be a representable integer", at: valueLocation)
                        }
                        level = parsedLevel
                    } else {
                        try params.set(value, for: try normalized(pname))
                    }
                }
            } else if case .continuation = currentToken {
                try advance()
            } else {
                try advance()
            }
        }

        try models.append(ParsedModel(
            name: name,
            type: type,
            level: level,
            parameters: try params.export(storage: &profileStorage),
            location: location,
            origin: try modelOrigin(location)
        ))
    }

    private mutating func parseParam(location: SourceLocation?) throws {
        while !isAtEnd && !isNewline {
            if case .identifier(let name) = currentToken {
                try advance()
                if case .equals = currentToken {
                    try advance()
                    let expression = try parseParameterExpression()
                    try parameters.set(expression, for: name)
                    try parameterDefinitions.append(ParsedParameterDefinition(
                        name: name,
                        value: expression,
                        location: location
                    ))
                }
            } else {
                try advance()
            }
        }
    }

    private mutating func parseParameterExpression() throws -> ParsedExpression {
        if case .leftBrace = currentToken {
            try advance()
            let expression = try parseExpression()
            guard case .rightBrace = currentToken else {
                throw ParserDiagnostic.error("Expected '}' after parameter expression", at: currentLocation)
            }
            try advance()
            return expression
        }
        return try parseExpression()
    }

    private mutating func parseTextPath() throws -> String {
        let path: String
        switch currentToken {
        case .string(let text), .identifier(let text):
            path = text
        case .quotedExpression(let text):
            path = try decodedQuotedText(text)
        case .unterminatedQuote:
            throw ParserDiagnostic.error("Unterminated quoted value", at: currentLocation)
        default:
            throw ParserDiagnostic.error("Expected source path", at: currentLocation)
        }
        guard !path.isEmpty else {
            throw ParserDiagnostic.error("Expected nonempty source path", at: currentLocation)
        }
        try advance()
        return path
    }

    private mutating func parseInclude(location: SourceLocation?) async throws {
        let path = try parseTextPath()

        try skipToEndOfLine()

        try controls.append(.include(path: path, location: location))

        // Resolve include if enabled
        if configuration.resolveIncludes {
            // Check include depth
            if includeDepth >= configuration.maxIncludeDepth {
                try diagnostics.append(.error(
                    (profileResources == nil ? "Maximum include depth (\(configuration.maxIncludeDepth)) exceeded" : "Maximum include depth exceeded"),
                    at: location
                ))
                return
            }

            do {
                try work?.charge(.dependencyExpansions, units: 1)
                if contextualResolver != nil {
                    try await resolveContextual(kind: .include, path: path, section: nil, location: location)
                } else {
                    let content = try await fileResolver.resolveInclude(path: path, relativeTo: fileName)
                    try recordDependency(content, kind: .include, path: path, section: nil, location: location)
                    try await parseIncludedContent(content)
                }
            } catch {
                if work != nil { throw error }
                try diagnostics.append(.error(
                    (profileResources == nil ? "Failed to include '\(path)': \(error)" : "Failed to include '': "),
                    at: location
                ))
            }
        }
    }

    private func originalStatementOffset(_ location: SourceLocation?) throws -> UInt64? {
        guard let profileResources, let coordinates else { return nil }
        guard let location else { throw SPICEBoundedSourceError.invalidSourceContext }
        return try coordinates.originalByteOffset(at: location, resources: profileResources)
    }

    private func modelOrigin(_ location: SourceLocation?) throws -> ParsedModelOrigin? {
        guard let captureID, let location else { return nil }
        return ParsedModelOrigin(captureID: captureID, location: location, ordinal: models.count,
            occurrenceID: document.occurrenceID, statementByteOffset: try originalStatementOffset(location),
            statementOrdinal: profileResources == nil ? nil : activeStatementOrdinal)
    }

    private func subcircuitOrigin(_ location: SourceLocation?, offset: UInt64?,
                                  statementOrdinal: UInt64) -> ParsedSubcircuitOrigin? {
        guard profileResources != nil, let captureID, let location else { return nil }
        return ParsedSubcircuitOrigin(captureID: captureID, location: location, ordinal: subcircuits.count,
            occurrenceID: document.occurrenceID, statementByteOffset: offset, statementOrdinal: statementOrdinal)
    }

    private mutating func childEnvironment() throws -> SPICEPreprocessingEnvironment {
        guard let profileResources, let environment else { throw SPICEBoundedSourceError.invalidEnvironment }
        var scratch = SPICEParseStorage(resources: profileResources)
        var replacements = SPICEAccountedCollection<SPICEPreprocessingParameter>(storageKind: .temporaryBytes)
        try parameters.forEach { name, expression in
            let formatted = try SPICEAccountedExpressionFormatting.format(expression, storage: &scratch)
            try replacements.append(SPICEPreprocessingParameter(name: name, expression: formatted), resources: profileResources)
        }
        let raw = try scratch.ownArray(replacements)
        return try environment.inheriting(replacing: raw, resources: profileResources, maximumPageByteCount: 256)
    }

    private mutating func resolveContextual(kind: SPICESourceDependencyEvent.Kind, path: String,
                                           section: String?, location: SourceLocation?) async throws {
        guard let profileResources, let contextualResolver, let occurrenceRegistry,
              let parentKey = document.sourceKey, let parentOccurrence = document.occurrenceID,
              let offset = try originalStatementOffset(location) else {
            throw SPICEBoundedSourceError.invalidSourceContext
        }
        let childEntry = try childEnvironment()
        let request = SPICESourceDependencyRequest(parentSourceKey: parentKey, parentOccurrenceID: parentOccurrence,
            statementByteOffset: offset, statementOrdinal: activeStatementOrdinal, kind: kind,
            literalRoute: path, parentSection: selectedSection, requestedChildSection: section, environment: childEntry)
        try profileResources.checkCancellation()
        let child: SPICESourceDocument
        do { child = try await contextualResolver.resolve(request) }
        catch { resolverFailed = true; throw error }
        try profileResources.checkCancellation()
        guard child.isInvocationAccounted, child.sourceKey != nil, let childOccurrence = child.occurrenceID else {
            throw SPICEBoundedSourceError.unaccountedSource
        }
        try checkOptionalContext(child.librarySection, equals: section)
        try await occurrenceRegistry.insert(childOccurrence)
        try profileStorage!.hold(child)
        try profileStorage!.hold(childEntry)
        try dependencyEvents.append(SPICESourceDependencyEvent(parentCaptureID: parentKey,
            childCaptureID: child.sourceKey, location: location, kind: kind, path: path,
            selectedSection: child.librarySection, ordinal: dependencyEvents.count, preprocessingContext: [:],
            parentOccurrenceID: parentOccurrence, childOccurrenceID: childOccurrence,
            statementByteOffset: offset, statementOrdinal: activeStatementOrdinal,
            parentSection: selectedSection, preprocessingIdentity: childEntry.identity))
        var childParser = SPICEParserImpl(document: child, configuration: configuration,
            fileResolver: NullFileResolver(), includeDepth: includeDepth + 1, resources: profileResources,
            environment: childEntry, contextualResolver: contextualResolver, occurrenceRegistry: occurrenceRegistry)
        let owned: SPICEOwnedParseResult
        do { owned = try await childParser.parseOwned() }
        catch {
            if childParser.resolverFailed { resolverFailed = true }
            throw error
        }
        try profileStorage!.hold(owned)
        try mergeIncludedResult(ParseResult(netlist: owned.netlist))
        try profileResources.checkCancellation()
    }

    private func checkOptionalContext(_ actual: String?, equals expected: String?) throws {
        guard let profileResources else { throw SPICEBoundedSourceError.invalidSourceContext }
        switch (actual, expected) {
        case (nil, nil): return
        case (let actual?, let expected?):
            try profileResources.charge(.lexicalBytes, units: UInt64(actual.utf8.count))
            try profileResources.charge(.lexicalBytes, units: UInt64(expected.utf8.count))
            try checkASCIIText(actual, capability: "Unicode source context comparison"); try checkASCIIText(expected, capability: "Unicode source context comparison")
            guard actual == expected else { throw SPICEBoundedSourceError.invalidSourceContext }
        default: throw SPICEBoundedSourceError.invalidSourceContext
        }
    }

    /// Parses included file content and merges it into the current state.
    private mutating func parseIncludedContent(_ document: SPICESourceDocument) async throws {
        var inheritedConditionalParameters = conditionalParameterExpressions
        for (name, expression) in try parameters.export(storage: &profileStorage) {
            inheritedConditionalParameters[try normalized(name)] = expression.description
        }

        var includedParser = SPICEParserImpl(
            document: document,
            configuration: configuration,
            fileResolver: fileResolver,
            includeDepth: includeDepth + 1,
            conditionalParameterExpressions: inheritedConditionalParameters,
            work: work,
            resources: profileResources
        )

        let result = try await includedParser.parse()
        if let childStorage = includedParser.profileStorage { try profileStorage!.hold(childStorage.immutableOwner()) }

        try mergeIncludedResult(result)
    }

    private mutating func mergeIncludedResult(_ result: ParseResult) throws {
        // Merge results
        if let netlist = result.netlist {
            try components.append(contentsOf: netlist.components)
            try models.append(contentsOf: netlist.models)
            try subcircuits.append(contentsOf: netlist.subcircuits)
            try analyses.append(contentsOf: netlist.analyses)
            try controls.append(contentsOf: netlist.controls)
            try parameterDefinitions.append(contentsOf: netlist.parameterDefinitions)
            try preprocessingEvents.append(contentsOf: netlist.preprocessingEvents)
            for event in netlist.dependencyEvents {
                try dependencyEvents.append(SPICESourceDependencyEvent(parentCaptureID: event.parentCaptureID,
                    childCaptureID: event.childCaptureID, location: event.location, kind: event.kind,
                    path: event.path, selectedSection: event.selectedSection, ordinal: dependencyEvents.count,
                    preprocessingContext: event.preprocessingContext,
                    parentOccurrenceID: event.parentOccurrenceID, childOccurrenceID: event.childOccurrenceID,
                    statementByteOffset: event.statementByteOffset, statementOrdinal: event.statementOrdinal,
                    parentSection: event.parentSection, preprocessingIdentity: event.preprocessingIdentity))
            }
            for (key, value) in netlist.parameters {
                try parameters.set(value, for: key)
            }
            for (key, value) in netlist.initialConditions {
                try initialConditions.set(value, for: key)
            }
            for (key, value) in netlist.nodeSets {
                try nodeSets.set(value, for: key)
            }
            try globalNodes.append(contentsOf: netlist.globalNodes)
        }

        // Propagate diagnostics
        try diagnostics.append(contentsOf: result.diagnostics)
    }

    private mutating func parseLib(location: SourceLocation?) async throws {
        let localSection: Bool
        if case .identifier = currentToken { localSection = true } else { localSection = false }
        let path = try parseTextPath()
        var section: String?

        if case .identifier(let s) = currentToken {
            section = s
            try advance()
        }

        try skipToEndOfLine()

        // A single bare .lib argument declares a local section; quoted paths or a
        // second argument are external library directives in the existing grammar.
        if section == nil, localSection, try hasLocalLibraryEnd(named: path) {
            return
        }
        try controls.append(.library(path: path, section: section, location: location))

        // Resolve library if enabled
        if configuration.resolveIncludes {
            // Check include depth
            if includeDepth >= configuration.maxIncludeDepth {
                try diagnostics.append(.error(
                    (profileResources == nil ? "Maximum include depth (\(configuration.maxIncludeDepth)) exceeded" : "Maximum include depth exceeded"),
                    at: location
                ))
                return
            }

            do {
                try work?.charge(.dependencyExpansions, units: 1)
                if contextualResolver != nil {
                    try await resolveContextual(kind: .externalLibrary, path: path, section: section, location: location)
                } else {
                    let content = try await fileResolver.resolveLibrary(path: path, section: section, relativeTo: fileName)
                    try recordDependency(content, kind: .externalLibrary, path: path, section: section, location: location)
                    try await parseIncludedContent(content)
                }
            } catch {
                if work != nil { throw error }
                try diagnostics.append(.error(
                    (profileResources == nil ? "Failed to include library '\(path)' section '\(section ?? "default")': \(error)" : "Failed to include library '' section '': "),
                    at: location
                ))
            }
        }
    }

    private mutating func hasLocalLibraryEnd(named name: String) throws -> Bool {
        for index in current..<tokens.count {
            try work?.charge(.tokens, units: 1)
            guard case .directive(let directive) = tokens[index].token else { continue }
            // A new local section owns its own closing delimiter. External library
            // directives with a section argument may still occur inside this section.
            if directive == "lib", index + 2 < tokens.count,
               case .identifier = tokens[index + 1].token,
               tokens[index + 2].token == .newline { return false }
            if directive == "endl" {
                if index + 1 < tokens.count, case .identifier(let closingName) = tokens[index + 1].token {
                    return try normalized(closingName) == (try normalized(name))
                }
                return true
            }
        }
        return false
    }

    private mutating func recordDependency(_ child: SPICESourceDocument,
        kind: SPICESourceDependencyEvent.Kind, path: String, section: String?, location: SourceLocation?) throws {
        var context = conditionalParameterExpressions
        for (name, expression) in try parameters.export(storage: &profileStorage) { context[try normalized(name)] = expression.description }
        try dependencyEvents.append(SPICESourceDependencyEvent(parentCaptureID: captureID,
            childCaptureID: child.captureID, location: location, kind: kind, path: path,
            selectedSection: section ?? selectedSection, ordinal: dependencyEvents.count,
            preprocessingContext: context))
    }

    private mutating func parseTransientAnalysis(location: SourceLocation?) throws {
        var stopTime: ParsedParameterValue = .numeric(1e-6)
        var stepTime: ParsedParameterValue?
        var startTime: ParsedParameterValue?
        var maxStep: ParsedParameterValue?
        var useInitialConditions = false

        if !(try currentTransientUICToken()), let value = try parseParameterValueIfPresent() {
            stepTime = value
        }

        if !(try currentTransientUICToken()), let value = try parseParameterValueIfPresent() {
            stopTime = value
        }

        if !(try currentTransientUICToken()), let value = try parseParameterValueIfPresent() {
            startTime = value
        }

        while !isAtEnd && !isNewline {
            if case .identifier(let id) = currentToken, try normalized(id) == "uic" {
                useInitialConditions = true
                try advance()
                continue
            }
            if maxStep == nil, let value = try parseParameterValueIfPresent() {
                maxStep = value
                continue
            }
            throw ParserDiagnostic.error(
                (profileResources == nil ? "Unsupported transient analysis token: \(try tokenEvidenceText(currentToken))" : "Unsupported transient analysis token"),
                at: currentLocation
            )
        }

        let analysisReservation = try profileStorage?.reservePayload(of: TransientAnalysisSpec.self)
        let command: ParsedAnalysisCommand = .transient(TransientAnalysisSpec(
            stopTime: stopTime,
            stepTime: stepTime,
            startTime: startTime,
            maxStep: maxStep,
            useInitialConditions: useInitialConditions
        ))

        if let analysisReservation { try profileStorage!.retain(command, reservation: analysisReservation) }

        try analyses.append(command)
        try skipToEndOfLine()
    }

    private mutating func currentTransientUICToken() throws -> Bool {
        if case .identifier(let id) = currentToken {
            return try normalized(id) == "uic"
        }
        return false
    }

    private mutating func parseACAnalysis(location: SourceLocation?) throws {
        var scaleType: ACScaleType = .decade
        var points = 10
        var startFreq: ParsedParameterValue = .numeric(1.0)
        var stopFreq: ParsedParameterValue = .numeric(1e6)

        if case .identifier(let scale) = currentToken {
            switch try normalized(scale) {
            case "dec": scaleType = .decade
            case "oct": scaleType = .octave
            case "lin": scaleType = .linear
            default: break
            }
            try advance()
        }

        points = try parseAnalysisPointCount(default: points)

        if let value = try parseParameterValueIfPresent() {
            startFreq = value
        }

        if let value = try parseParameterValueIfPresent() {
            stopFreq = value
        }

        let analysisReservation = try profileStorage?.reservePayload(of: ACAnalysisSpec.self)
        let command: ParsedAnalysisCommand = .ac(try ACAnalysisSpec(
            scaleType: scaleType,
            numberOfPoints: points,
            startFrequency: startFreq,
            stopFrequency: stopFreq
        ))

        if let analysisReservation { try profileStorage!.retain(command, reservation: analysisReservation) }

        try analyses.append(command)
        try skipToEndOfLine()
    }

    private mutating func parseDCAnalysis(location: SourceLocation?) throws {
        guard case .identifier(let source) = currentToken else {
            throw ParserDiagnostic.error("Expected source name for DC sweep", at: currentLocation)
        }
        try advance()

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

        let analysisReservation = try profileStorage?.reservePayload(of: DCAnalysisSpec.self)
        let command: ParsedAnalysisCommand = .dc(DCAnalysisSpec(
            source: source,
            startValue: start,
            stopValue: stop,
            stepValue: step
        ))

        if let analysisReservation { try profileStorage!.retain(command, reservation: analysisReservation) }

        try analyses.append(command)
        try skipToEndOfLine()
    }

    /// Parses .noise directive: .noise V(out[,ref]) Vin dec|oct|lin np fstart fstop
    private mutating func parseNoiseAnalysis(location: SourceLocation?) throws {
        // Parse output specification V(node) or V(node,ref)
        guard case .identifier(let vName) = currentToken, try normalized(vName) == "v" else {
            throw ParserDiagnostic.error("Expected V(node) for noise output", at: currentLocation)
        }
        try advance()

        guard case .leftParen = currentToken else {
            throw ParserDiagnostic.error("Expected '(' after V", at: currentLocation)
        }
        try advance()

        guard case .identifier(let outputNode) = currentToken else {
            throw ParserDiagnostic.error("Expected output node name", at: currentLocation)
        }
        try advance()

        var referenceNode: String?
        if case .comma = currentToken {
            try advance()
            if case .identifier(let ref) = currentToken {
                referenceNode = ref
                try advance()
            }
        }

        guard case .rightParen = currentToken else {
            throw ParserDiagnostic.error("Expected ')' after node specification", at: currentLocation)
        }
        try advance()

        // Parse input source
        guard case .identifier(let inputSource) = currentToken else {
            throw ParserDiagnostic.error("Expected input source name", at: currentLocation)
        }
        try advance()

        // Parse sweep type
        var scaleType: ACScaleType = .decade
        if case .identifier(let scale) = currentToken {
            switch try normalized(scale) {
            case "dec": scaleType = .decade
            case "oct": scaleType = .octave
            case "lin": scaleType = .linear
            default: break
            }
            try advance()
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

        let analysisReservation = try profileStorage?.reservePayload(of: NoiseAnalysisSpec.self)
        let command: ParsedAnalysisCommand = .noise(try NoiseAnalysisSpec(
            outputNode: outputNode,
            referenceNode: referenceNode,
            inputSource: inputSource,
            scaleType: scaleType,
            numberOfPoints: points,
            startFrequency: startFreq,
            stopFrequency: stopFreq
        ))

        if let analysisReservation { try profileStorage!.retain(command, reservation: analysisReservation) }

        try analyses.append(command)
        try skipToEndOfLine()
    }

    /// Parses .tf directive: .tf V(out) Vin
    private mutating func parseTransferFunctionAnalysis(location: SourceLocation?) throws {
        // Parse output specification
        guard case .identifier(let vName) = currentToken, try normalized(vName) == "v" else {
            throw ParserDiagnostic.error("Expected V(output) for transfer function", at: currentLocation)
        }
        try advance()

        guard case .leftParen = currentToken else {
            throw ParserDiagnostic.error("Expected '(' after V", at: currentLocation)
        }
        try advance()

        guard case .identifier(let output) = currentToken else {
            throw ParserDiagnostic.error("Expected output node name", at: currentLocation)
        }
        try advance()

        guard case .rightParen = currentToken else {
            throw ParserDiagnostic.error("Expected ')' after output node", at: currentLocation)
        }
        try advance()

        // Parse input source
        guard case .identifier(let input) = currentToken else {
            throw ParserDiagnostic.error("Expected input source name", at: currentLocation)
        }
        try advance()

        let analysisReservation = try profileStorage?.reservePayload(of: TransferFunctionSpec.self)
        let command: ParsedAnalysisCommand = .transferFunction(TransferFunctionSpec(
            output: try decorated("V(", output, ")"),
            input: input
        ))

        if let analysisReservation { try profileStorage!.retain(command, reservation: analysisReservation) }

        try analyses.append(command)
        try skipToEndOfLine()
    }

    /// Parses .sens directive: .sens V(out) [ac dec np fstart fstop]
    private mutating func parseSensitivityAnalysis(location: SourceLocation?) throws {
        // Parse output specification
        guard case .identifier(let vName) = currentToken, try normalized(vName) == "v" else {
            throw ParserDiagnostic.error("Expected V(output) for sensitivity", at: currentLocation)
        }
        try advance()

        guard case .leftParen = currentToken else {
            throw ParserDiagnostic.error("Expected '(' after V", at: currentLocation)
        }
        try advance()

        guard case .identifier(let output) = currentToken else {
            throw ParserDiagnostic.error("Expected output node name", at: currentLocation)
        }
        try advance()

        guard case .rightParen = currentToken else {
            throw ParserDiagnostic.error("Expected ')' after output node", at: currentLocation)
        }
        try advance()

        // Check for optional AC specification
        var acSpec: ACAnalysisSpec?
        if case .identifier(let acId) = currentToken, try normalized(acId) == "ac" {
            try advance()

            guard case .identifier(let scale) = currentToken else {
                throw ParserDiagnostic.error(
                    "Expected AC sensitivity scale dec, oct, or lin",
                    at: currentLocation
                )
            }
            let scaleType: ACScaleType
            switch try normalized(scale) {
            case "dec": scaleType = .decade
            case "oct": scaleType = .octave
            case "lin": scaleType = .linear
            default:
                throw ParserDiagnostic.error(
                    "Expected AC sensitivity scale dec, oct, or lin",
                    at: currentLocation
                )
            }
            try advance()

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

        let analysisReservation = try profileStorage?.reservePayload(of: SensitivitySpec.self)
        let command: ParsedAnalysisCommand = .sensitivity(SensitivitySpec(
            output: try decorated("V(", output, ")"),
            acSpec: acSpec
        ))

        if let analysisReservation { try profileStorage!.retain(command, reservation: analysisReservation) }

        try analyses.append(command)
        try skipToEndOfLine()
    }

    /// Parses .four directive: .four freq V(out) [V(out2) ...]
    private mutating func parseFourierAnalysis(location: SourceLocation?) throws {
        // Parse fundamental frequency
        var frequency: ParsedParameterValue = .numeric(1e6)
        if let n = try parseNumericTokenIfPresent() {
            frequency = .numeric(n)
        }

        // Parse output variables
        var outputs = SPICEParserBuffer<String>(resources: profileResources)
        while !isAtEnd && !isNewline {
            if case .identifier(let vName) = currentToken, try normalized(vName) == "v" {
                try advance()
                if case .leftParen = currentToken {
                    try advance()
                    if case .identifier(let node) = currentToken {
                        try outputs.append(try decorated("V(", node, ")"))
                        try advance()
                    }
                    if case .rightParen = currentToken {
                        try advance()
                    }
                }
            } else if case .identifier(let iName) = currentToken, try normalized(iName) == "i" {
                try advance()
                if case .leftParen = currentToken {
                    try advance()
                    if case .identifier(let device) = currentToken {
                        try outputs.append(try decorated("I(", device, ")"))
                        try advance()
                    }
                    if case .rightParen = currentToken {
                        try advance()
                    }
                }
            } else {
                try advance()
            }
        }

        let analysisReservation = try profileStorage?.reservePayload(of: FourierSpec.self)
        let command: ParsedAnalysisCommand = .fourier(FourierSpec(
            frequency: frequency,
            outputs: try outputs.export(storage: &profileStorage)
        ))

        if let analysisReservation { try profileStorage!.retain(command, reservation: analysisReservation) }

        try analyses.append(command)
        try skipToEndOfLine()
    }

    /// Parses .pz directive: .pz node1 node2 node3 node4 vol|cur pz|pol|zer
    private mutating func parsePoleZeroAnalysis(location: SourceLocation?) throws {
        // Parse 4 nodes
        var nodes = SPICEParserBuffer<String>(resources: profileResources)
        for _ in 0..<4 {
            if case .identifier(let node) = currentToken {
                try nodes.append(node)
                try advance()
            } else if case .number(let n) = currentToken {
                try nodes.append(try integerText(n))
                try advance()
            } else if case .invalidNumericLiteral(let text) = currentToken {
                throw ParserDiagnostic.error((profileResources == nil ? "Invalid numeric literal '\(text)'" : "Invalid numeric literal ''"), at: currentLocation)
            } else if case .invalidNumericSuffix(let suffix) = currentToken {
                throw ParserDiagnostic.error((profileResources == nil ? "Unknown numeric suffix '\(suffix)'" : "Unknown numeric suffix ''"), at: currentLocation)
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
            switch try normalized(typeStr) {
            case "vol": transferType = .voltage
            case "cur": transferType = .current
            default:
                throw ParserDiagnostic.error(
                    "Expected pole-zero transfer type vol or cur",
                    at: currentLocation
                )
            }
            try advance()
        } else {
            throw ParserDiagnostic.error(
                "Expected pole-zero transfer type vol or cur",
                at: currentLocation
            )
        }

        // Parse analysis type (pz, pol, or zer)
        var analysisType: PoleZeroSpec.PoleZeroType = .both
        if case .identifier(let modeStr) = currentToken {
            switch try normalized(modeStr) {
            case "pz": analysisType = .both
            case "pol": analysisType = .poles
            case "zer": analysisType = .zeros
            default:
                throw ParserDiagnostic.error(
                    "Expected pole-zero analysis type pz, pol, or zer",
                    at: currentLocation
                )
            }
            try advance()
        } else {
            throw ParserDiagnostic.error(
                "Expected pole-zero analysis type pz, pol, or zer",
                at: currentLocation
            )
        }

        let analysisReservation = try profileStorage?.reservePayload(of: PoleZeroSpec.self)
        let command: ParsedAnalysisCommand = .poleZero(PoleZeroSpec(
            inputNode: nodes[0],
            inputReference: nodes[1],
            outputNode: nodes[2],
            outputReference: nodes[3],
            transferType: transferType,
            analysisType: analysisType
        ))

        if let analysisReservation { try profileStorage!.retain(command, reservation: analysisReservation) }

        try analyses.append(command)
        try skipToEndOfLine()
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
        try advance()

        // Parse the inner analysis based on type
        var innerAnalysis: ParsedAnalysisCommand?
        switch try normalized(analysisName) {
        case "tran":
            var stopTime: ParsedParameterValue = .numeric(1e-6)
            var stepTime: ParsedParameterValue?

            if let n = try parseNumericTokenIfPresent() {
                stepTime = .numeric(n)
            }

            if let n = try parseNumericTokenIfPresent() {
                stopTime = .numeric(n)
            }

            let innerReservation = try profileStorage?.reservePayload(of: TransientAnalysisSpec.self)
            let command: ParsedAnalysisCommand = .transient(TransientAnalysisSpec(
                stopTime: stopTime,
                stepTime: stepTime
            ))
            if let innerReservation { try profileStorage!.retain(command, reservation: innerReservation) }
            innerAnalysis = command

        case "ac":
            var scaleType: ACScaleType = .decade
            var points = 10
            var startFreq: ParsedParameterValue = .numeric(1.0)
            var stopFreq: ParsedParameterValue = .numeric(1e6)

            if case .identifier(let scale) = currentToken {
                switch try normalized(scale) {
                case "dec": scaleType = .decade
                case "oct": scaleType = .octave
                case "lin": scaleType = .linear
                default: break
                }
                try advance()
            }

            points = try parseAnalysisPointCount(default: points)

            if let n = try parseNumericTokenIfPresent() {
                startFreq = .numeric(n)
            }

            if let n = try parseNumericTokenIfPresent() {
                stopFreq = .numeric(n)
            }

            let innerReservation = try profileStorage?.reservePayload(of: ACAnalysisSpec.self)
            let command: ParsedAnalysisCommand = .ac(try ACAnalysisSpec(
                scaleType: scaleType,
                numberOfPoints: points,
                startFrequency: startFreq,
                stopFrequency: stopFreq
            ))
            if let innerReservation { try profileStorage!.retain(command, reservation: innerReservation) }
            innerAnalysis = command

        case "dc":
            guard case .identifier(let source) = currentToken else {
                throw ParserDiagnostic.error("Expected source name for DC sweep", at: currentLocation)
            }
            try advance()

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

            let innerReservation = try profileStorage?.reservePayload(of: DCAnalysisSpec.self)
            let command: ParsedAnalysisCommand = .dc(DCAnalysisSpec(
                source: source,
                startValue: start,
                stopValue: stop,
                stepValue: step
            ))
            if let innerReservation { try profileStorage!.retain(command, reservation: innerReservation) }
            innerAnalysis = command

        default:
            throw ParserDiagnostic.error((profileResources == nil ? "Unsupported analysis type for Monte Carlo: \(analysisName)" : "Unsupported analysis type for Monte Carlo: "), at: currentLocation)
        }

        // Parse optional seed
        var seed: Int?
        while !isAtEnd && !isNewline {
            if case .identifier(let paramName) = currentToken {
                if try normalized(paramName) == "seed" {
                    try advance()
                    if case .equals = currentToken {
                        try advance()
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
                try advance()
            }
        }

        if let inner = innerAnalysis {
            let analysisReservation = try profileStorage?.reservePayload(of: MonteCarloSpec.self)
            let command: ParsedAnalysisCommand = .monteCarlo(try MonteCarloSpec(
                analysis: inner,
                iterations: iterations,
                seed: seed
            ))
            if let analysisReservation { try profileStorage!.retain(command, reservation: analysisReservation) }
            try analyses.append(command)
        }
        try skipToEndOfLine()
    }

    /// Parses .meas directive: .meas tran|ac|dc name <measurement_type> <parameters>
    private mutating func parseMeasure(location: SourceLocation?) throws {
        // Parse analysis type
        var analysisType: OutputAnalysisType = .transient
        if case .identifier(let typeStr) = currentToken {
            switch try normalized(typeStr) {
            case "dc": analysisType = .dc
            case "ac": analysisType = .ac
            case "tran": analysisType = .transient
            case "op": analysisType = .op
            default: break
            }
            try advance()
        }

        // Parse result name
        guard case .identifier(let resultName) = currentToken else {
            throw ParserDiagnostic.error("Expected measurement result name", at: currentLocation)
        }
        try advance()

        // Parse measurement type keyword or trigger/target
        var measureType: MeasureType?

        guard case .identifier(let keyword) = currentToken else {
            throw ParserDiagnostic.error("Expected measurement type", at: currentLocation)
        }
        let lowerKeyword = try normalized(keyword)

        switch lowerKeyword {
            case "trig":
                // Delay measurement: trig ... targ ...
                try advance()
                let trigVar = try parseOutputVariable()
                var trigVal: ParsedParameterValue = .numeric(0.5)

                // Parse val=
                while !isAtEnd && !isNewline {
                    if case .identifier(let param) = currentToken {
                        let lowerParam = try normalized(param)
                        if lowerParam == "val" {
                            try advance()
                            if case .equals = currentToken { try advance() }
                            trigVal = try parseParameterValue()
                        } else if lowerParam == "targ" {
                            break
                        } else {
                            try advance()
                        }
                    } else {
                        break
                    }
                }

                // Parse targ
                guard case .identifier(let targ) = currentToken, try normalized(targ) == "targ" else {
                    throw ParserDiagnostic.error("Expected 'targ' in delay measurement", at: currentLocation)
                }
                try advance()

                let targVar = try parseOutputVariable()
                var targVal: ParsedParameterValue = .numeric(0.5)

                // Parse val=
                while !isAtEnd && !isNewline {
                    if case .identifier(let param) = currentToken {
                        if try normalized(param) == "val" {
                            try advance()
                            if case .equals = currentToken { try advance() }
                            targVal = try parseParameterValue()
                        } else {
                            try advance()
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
                try advance()
                let expr = try parseExpression()
                measureType = .when(condition: expr, target: nil)

            case "find":
                try advance()
                let variable = try parseOutputVariable()
                var atValue: ParsedParameterValue = .numeric(0)

                if case .identifier(let atKeyword) = currentToken, try normalized(atKeyword) == "at" {
                    try advance()
                    if case .equals = currentToken { try advance() }
                    atValue = try parseParameterValue()
                }

                measureType = .find(variable: variable, at: atValue)

            case "avg", "average":
                try advance()
                let variable = try parseOutputVariable()
                let (from, to) = try parseMeasureRange()
                measureType = .average(variable: variable, from: from, to: to)

            case "rms":
                try advance()
                let variable = try parseOutputVariable()
                let (from, to) = try parseMeasureRange()
                measureType = .rms(variable: variable, from: from, to: to)

            case "min":
                try advance()
                let variable = try parseOutputVariable()
                let (from, to) = try parseMeasureRange()
                measureType = .min(variable: variable, from: from, to: to)

            case "max":
                try advance()
                let variable = try parseOutputVariable()
                let (from, to) = try parseMeasureRange()
                measureType = .max(variable: variable, from: from, to: to)

            case "pp":
                try advance()
                let variable = try parseOutputVariable()
                let (from, to) = try parseMeasureRange()
                measureType = .peakToPeak(variable: variable, from: from, to: to)

            case "integ":
                try advance()
                let variable = try parseOutputVariable()
                let (from, to) = try parseMeasureRange()
                measureType = .integral(variable: variable, from: from, to: to)

            case "rise_time":
                try advance()
                let variable = try parseOutputVariable()
                var low = 0.1
                var high = 0.9

                while !isAtEnd && !isNewline {
                    if case .identifier(let param) = currentToken {
                        let lowerParam = try normalized(param)
                        if lowerParam == "low" || lowerParam == "from" {
                            try advance()
                            if case .equals = currentToken { try advance() }
                            if let n = try parseNumericTokenIfPresent() {
                                low = n
                            }
                        } else if lowerParam == "high" || lowerParam == "to" {
                            try advance()
                            if case .equals = currentToken { try advance() }
                            if let n = try parseNumericTokenIfPresent() {
                                high = n
                            }
                        } else {
                            try advance()
                        }
                    } else {
                        break
                    }
                }

                measureType = .riseTime(variable: variable, lowThreshold: low, highThreshold: high)

            case "fall_time":
                try advance()
                let variable = try parseOutputVariable()
                var high = 0.9
                var low = 0.1

                while !isAtEnd && !isNewline {
                    if case .identifier(let param) = currentToken {
                        let lowerParam = try normalized(param)
                        if lowerParam == "high" || lowerParam == "from" {
                            try advance()
                            if case .equals = currentToken { try advance() }
                            if let n = try parseNumericTokenIfPresent() {
                                high = n
                            }
                        } else if lowerParam == "low" || lowerParam == "to" {
                            try advance()
                            if case .equals = currentToken { try advance() }
                            if let n = try parseNumericTokenIfPresent() {
                                low = n
                            }
                        } else {
                            try advance()
                        }
                    } else {
                        break
                    }
                }

                measureType = .fallTime(variable: variable, highThreshold: high, lowThreshold: low)

        default:
            try advance()
            measureType = .unsupported(
                keyword: lowerKeyword,
                arguments: try collectRemainingLineTokenDescriptions(),
                reason: (profileResources == nil ? "Measurement keyword '\(keyword)' is not supported by CoreSpice" : "Measurement keyword is not supported by CoreSpice")
            )
        }

        if let mType = measureType {
            try controls.append(.measure(MeasureSpec(
                analysisType: analysisType,
                resultName: resultName,
                measureType: mType,
                location: location
            )))
        }

        try skipToEndOfLine()
    }

    private mutating func collectRemainingLineTokenDescriptions() throws -> [String] {
        var descriptions = SPICEParserBuffer<String>(resources: profileResources)
        while !isAtEnd && !isNewline {
            try descriptions.append(try tokenEvidenceText(currentToken))
            try advance()
        }
        return try descriptions.export(storage: &profileStorage)
    }

    private mutating func tokenEvidenceText(_ token: SPICEToken) throws -> String {
        try profileResources?.checkCancellation()
        try profileResources?.charge(.tokens, units: 1)
        switch token {
        case .directive(let name):
            return try decorated(".", name, "")
        case .comment(let text):
            try checkASCIIText(text, capability: "Cooperative Unicode token evidence")
            return text
        case .number(let value):
            return try doubleText(value)
        case .identifier(let name):
            try checkASCIIText(name, capability: "Cooperative Unicode token evidence")
            return name
        case .string(let value):
            return try decorated("\"", value, "\"")
        case .quotedExpression(let value):
            return try decorated("'", value, "'")
        case .invalidCharacter(let character):
            return try characterText(character)
        case .invalidNumericLiteral(let text):
            try checkASCIIText(text, capability: "Cooperative Unicode token evidence")
            return text
        case .invalidNumericSuffix(let suffix):
            try checkASCIIText(suffix, capability: "Cooperative Unicode token evidence")
            return suffix
        default:
            if profileResources != nil { return try boundedTokenEvidence(token) }
            return token.description
        }
    }

    /// Parses .func name(arg, ...) = expression.
    private mutating func parseFunction(location: SourceLocation?) throws {
        guard case .identifier(let name) = currentToken else {
            throw ParserDiagnostic.error("Expected function name", at: currentLocation)
        }
        try advance()

        var parameters = SPICEParserBuffer<String>(resources: profileResources)
        if case .leftParen = currentToken {
            try advance()
            while !isAtEnd {
                if case .rightParen = currentToken {
                    try advance()
                    break
                }
                if case .identifier(let parameter) = currentToken {
                    try parameters.append(parameter)
                    try advance()
                    if case .comma = currentToken {
                        try advance()
                    }
                } else {
                    throw ParserDiagnostic.error("Expected function parameter name", at: currentLocation)
                }
            }
        }

        if case .equals = currentToken {
            try advance()
        }

        let body = try parseParameterExpression()
        try controls.append(.function(name: name, parameters: try parameters.export(storage: &profileStorage), body: body, location: location))
        try skipToEndOfLine()
    }

    /// Helper to parse optional from=/to= range for measure commands
    private mutating func parseMeasureRange() throws -> (ParsedParameterValue?, ParsedParameterValue?) {
        var from: ParsedParameterValue?
        var to: ParsedParameterValue?

        while !isAtEnd && !isNewline {
            if case .identifier(let param) = currentToken {
                let lowerParam = try normalized(param)
                if lowerParam == "from" {
                    try advance()
                    if case .equals = currentToken { try advance() }
                    from = try parseParameterValue()
                } else if lowerParam == "to" {
                    try advance()
                    if case .equals = currentToken { try advance() }
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
        try controls.append(.temp(value: value, location: location))
        try skipToEndOfLine()
    }

    private mutating func parseIC(location: SourceLocation?) throws {
        while !isAtEnd && !isNewline {
            if let assignment = try parseNodeVoltageAssignment() {
                try initialConditions.set(assignment.value, for: assignment.node)
                try controls.append(.initialCondition(
                    node: assignment.node,
                    voltage: assignment.value,
                    location: location
                ))
            } else {
                try advance()
            }
        }
    }

    private mutating func parseNodeset(location: SourceLocation?) throws {
        while !isAtEnd && !isNewline {
            if let assignment = try parseNodeVoltageAssignment() {
                try nodeSets.set(assignment.value, for: assignment.node)
                try controls.append(.nodeSet(
                    node: assignment.node,
                    voltage: assignment.value,
                    location: location
                ))
            } else {
                try advance()
            }
        }
    }

    private mutating func parseNodeVoltageAssignment() throws -> (node: String, value: ParsedParameterValue)? {
        let saved = current
        var node: String?

        if case .identifier(let name) = currentToken, try normalized(name) == "v" {
            try advance()
            guard case .leftParen = currentToken else {
                current = saved
                return nil
            }
            try advance()
            if case .identifier(let parsedNode) = currentToken {
                node = parsedNode
                try advance()
            } else if case .number(let numericNode) = currentToken {
                node = try parseNumericNodeName(numericNode)
                try advance()
            } else if case .invalidNumericLiteral(let text) = currentToken {
                throw ParserDiagnostic.error((profileResources == nil ? "Invalid numeric literal '\(text)'" : "Invalid numeric literal ''"), at: currentLocation)
            } else if case .invalidNumericSuffix(let suffix) = currentToken {
                throw ParserDiagnostic.error((profileResources == nil ? "Unknown numeric suffix '\(suffix)'" : "Unknown numeric suffix ''"), at: currentLocation)
            }
            guard case .rightParen = currentToken else {
                current = saved
                return nil
            }
            try advance()
        } else if case .identifier(let parsedNode) = currentToken {
            node = parsedNode
            try advance()
        }

        guard let node else {
            current = saved
            return nil
        }
        guard case .equals = currentToken else {
            current = saved
            return nil
        }
        try advance()

        let value = try parseParameterValue()
        return (node: node, value: value)
    }

    private mutating func parseGlobal(location: SourceLocation?) throws {
        while !isAtEnd && !isNewline {
            if case .identifier(let node) = currentToken {
                try globalNodes.append(node)
                try advance()
            } else {
                try advance()
            }
        }
    }

    private mutating func parseOption(location: SourceLocation?) throws {
        while !isAtEnd && !isNewline {
            if case .identifier(let name) = currentToken {
                try advance()
                var value: ParsedParameterValue?
                if case .equals = currentToken {
                    try advance()
                    value = try parseParameterValue()
                }
                try controls.append(.option(name: name, value: value, location: location))
            } else {
                try advance()
            }
        }
    }

    private mutating func parsePrint(location: SourceLocation?) throws {
        var analysisType: OutputAnalysisType = .dc

        if case .identifier(let type) = currentToken {
            switch try normalized(type) {
            case "dc": analysisType = .dc
            case "ac": analysisType = .ac
            case "tran": analysisType = .transient
            case "op": analysisType = .op
            default: break
            }
            try advance()
        }

        var variables = SPICEParserBuffer<OutputVariable>(resources: profileResources)
        while !isAtEnd && !isNewline {
            let v = try parseOutputVariable()
            try variables.append(v)
        }

        try controls.append(.print(PrintSpec(
            analysisType: analysisType,
            variables: try variables.export(storage: &profileStorage),
            location: location
        )))
    }

    private mutating func parsePlot(location: SourceLocation?) throws {
        var analysisType: OutputAnalysisType = .dc

        if case .identifier(let type) = currentToken {
            switch try normalized(type) {
            case "dc": analysisType = .dc
            case "ac": analysisType = .ac
            case "tran": analysisType = .transient
            case "op": analysisType = .op
            default: break
            }
            try advance()
        }

        var variables = SPICEParserBuffer<OutputVariable>(resources: profileResources)
        while !isAtEnd && !isNewline {
            let v = try parseOutputVariable()
            try variables.append(v)
        }

        try controls.append(.plot(PlotSpec(
            analysisType: analysisType,
            variables: try variables.export(storage: &profileStorage),
            location: location
        )))
    }

    private mutating func parseSave(location: SourceLocation?) throws {
        let variables = try parseOutputVariableTexts()
        try controls.append(.save(variables: variables, location: location))
    }

    private mutating func parseProbe(location: SourceLocation?) throws {
        let variables = try parseOutputVariableTexts()
        try controls.append(.probe(variables: variables, location: location))
    }

    private mutating func parseOutputVariableTexts() throws -> [String] {
        var variables = SPICEParserBuffer<String>(resources: profileResources)
        while !isAtEnd && !isNewline {
            if let variable = try parseOutputVariableText() {
                try variables.append(variable)
            } else {
                try advance()
            }
        }
        return try variables.export(storage: &profileStorage)
    }

    private mutating func parseOutputVariableText() throws -> String? {
        guard case .identifier(let name) = currentToken else { return nil }
        try advance()

        let lower = try normalized(name)
        if lower == "v" || lower == "i" {
            guard case .leftParen = currentToken else { return name }
            try advance()
            var parts = SPICEParserBuffer<String>(resources: profileResources)
            while !isAtEnd {
                if case .rightParen = currentToken {
                    try advance()
                    break
                }
                if case .identifier(let value) = currentToken {
                    try parts.append(value)
                    try advance()
                } else if case .number(let numericValue) = currentToken {
                    try parts.append(try parseNumericNodeName(numericValue))
                    try advance()
                } else if case .comma = currentToken {
                    try advance()
                } else {
                    break
                }
            }
            return try decorated(lower, decorated("(", joined(parts, separator: ","), ")"), "")
        }

        return name
    }

    private mutating func parseOutputVariable() throws -> OutputVariable {
        if case .leftBrace = currentToken {
            try advance()
            let expression = try parseExpression()
            guard case .rightBrace = currentToken else {
                throw ParserDiagnostic.error("Expected '}' after output expression", at: currentLocation)
            }
            try advance()
            let variableReservation = try profileStorage?.reservePayload(of: ParsedExpression.self)
            let variable = OutputVariable.expression(expression)
            if let variableReservation { try profileStorage!.retain(variable, reservation: variableReservation) }
            return variable
        }

        guard case .identifier(let name) = currentToken else {
            throw ParserDiagnostic.error("Expected variable name", at: currentLocation)
        }
        try advance()

        // Check for V(...) or I(...)
        let lower = try normalized(name)
        if lower == "mag" || lower == "magnitude" || lower == "phase" || lower == "ph" || lower == "real" || lower == "re" || lower == "imag" || lower == "im" || lower == "db" {
            guard case .leftParen = currentToken else {
                throw ParserDiagnostic.error(
                    (profileResources == nil ? "Expected '(' after output modifier \(name)" : "Expected '(' after output modifier "),
                    at: currentLocation
                )
            }
            try advance()
            let inner = try parseOutputVariable()
            guard case .rightParen = currentToken else {
                throw ParserDiagnostic.error(
                    (profileResources == nil ? "Expected ')' after output modifier \(name)" : "Expected ')' after output modifier "),
                    at: currentLocation
                )
            }
            try advance()
            switch lower {
            case "mag", "magnitude":
                let variableReservation = try profileStorage?.reservePayload(of: OutputVariable.self)
                let variable = OutputVariable.magnitude(inner)
                if let variableReservation { try profileStorage!.retain(variable, reservation: variableReservation) }
                return variable
            case "phase", "ph":
                let variableReservation = try profileStorage?.reservePayload(of: OutputVariable.self)
                let variable = OutputVariable.phase(inner)
                if let variableReservation { try profileStorage!.retain(variable, reservation: variableReservation) }
                return variable
            case "real", "re":
                let variableReservation = try profileStorage?.reservePayload(of: OutputVariable.self)
                let variable = OutputVariable.real(inner)
                if let variableReservation { try profileStorage!.retain(variable, reservation: variableReservation) }
                return variable
            case "imag", "im":
                let variableReservation = try profileStorage?.reservePayload(of: OutputVariable.self)
                let variable = OutputVariable.imaginary(inner)
                if let variableReservation { try profileStorage!.retain(variable, reservation: variableReservation) }
                return variable
            default:
                let variableReservation = try profileStorage?.reservePayload(of: OutputVariable.self)
                let variable = OutputVariable.dB(inner)
                if let variableReservation { try profileStorage!.retain(variable, reservation: variableReservation) }
                return variable
            }
        }
        if lower == "v" {
            if case .leftParen = currentToken {
                try advance()
                guard let node = try parseOutputNodeName() else {
                    throw ParserDiagnostic.error("Expected node name", at: currentLocation)
                }
                var refNode: String?
                if case .comma = currentToken {
                    try advance()
                    if let ref = try parseOutputNodeName() {
                        refNode = ref
                    }
                }
                if case .rightParen = currentToken {
                    try advance()
                }
                let variableReservation = try profileStorage?.reservePayload(of: (String, String?).self)
                let variable = OutputVariable.voltage(node: node, reference: refNode)
                if let variableReservation { try profileStorage!.retain(variable, reservation: variableReservation) }
                return variable
            }
        } else if lower == "i" {
            if case .leftParen = currentToken {
                try advance()
                guard case .identifier(let device) = currentToken else {
                    throw ParserDiagnostic.error("Expected device name", at: currentLocation)
                }
                try advance()
                if case .rightParen = currentToken {
                    try advance()
                }
                let variableReservation = try profileStorage?.reservePayload(of: String.self)
                let variable = OutputVariable.current(device: device)
                if let variableReservation { try profileStorage!.retain(variable, reservation: variableReservation) }
                return variable
            }
        }

        // Generic identifier
        let variableReservation = try profileStorage?.reservePayload(of: (String, String?).self)
        let variable = OutputVariable.voltage(node: name, reference: nil)
        if let variableReservation { try profileStorage!.retain(variable, reservation: variableReservation) }
        return variable
    }

    private mutating func parseOutputNodeName() throws -> String? {
        if case .identifier(let node) = currentToken {
            try advance()
            return node
        }
        if case .number(let numericNode) = currentToken {
            let node = try parseNumericNodeName(numericNode)
            try advance()
            return node
        }
        return nil
    }

    private mutating func parseNumericNodeName(_ numericNode: Double) throws -> String {
        guard numericNode.isFinite,
              numericNode >= 0,
              numericNode.rounded(.towardZero) == numericNode else {
            throw ParserDiagnostic.error(
                "Numeric node names must be non-negative integers.",
                at: currentLocation
            )
        }
        return try integerText(numericNode)
    }

    private func checkASCIIText(_ text: String, capability: String) throws {
        guard let resources = profileResources else { return }
        var index = 0
        for byte in text.utf8 {
            try resources.charge(.lexicalBytes, units: 1)
            if index.isMultiple(of: 256) { try resources.checkCancellation() }
            guard byte < 128 else { throw SPICEBoundedSourceError.unsupportedBudgetCapability(capability) }
            index += 1
        }
        try resources.checkCancellation()
    }

    private mutating func normalized(_ text: String, uppercase: Bool = false) throws -> String {
        guard let resources = profileResources else { return uppercase ? text.uppercased() : text.lowercased() }
        var count = 0
        for byte in text.utf8 {
            try resources.charge(.lexicalBytes, units: 1)
            if count.isMultiple(of: 256) { try resources.checkCancellation() }
            guard byte < 128 else { throw SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode case normalization") }
            let (next, overflow) = count.addingReportingOverflow(1)
            guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
            count = next
        }
        let receipt = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(count))
        try resources.charge(.projectedBytes, units: UInt64(count))
        var output = ""
        output.reserveCapacity(count)
        for byte in text.utf8 {
            try resources.charge(.lexicalBytes, units: 1)
            try resources.checkCancellation()
            let mapped = uppercase ? (byte >= 97 && byte <= 122 ? byte - 32 : byte) : (byte >= 65 && byte <= 90 ? byte + 32 : byte)
            output.append(Character(UnicodeScalar(mapped)))
        }
        try profileStorage!.retain(output, reservation: receipt)
        return output
    }

    private mutating func joined<Values: Collection>(_ values: Values, separator: String) throws -> String where Values.Element == String {
        guard let resources = profileResources else { return values.joined(separator: separator) }
        var byteCount = 0
        var first = true
        func add(_ text: String) throws {
            for byte in text.utf8 {
                try resources.charge(.lexicalBytes, units: 1)
                if byteCount.isMultiple(of: 256) { try resources.checkCancellation() }
                guard byte < 128 else { throw SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode parser text composition") }
                let (next, overflow) = byteCount.addingReportingOverflow(1)
                guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
                byteCount = next
            }
        }
        for value in values {
            try resources.checkCancellation()
            if !first { try add(separator) }
            first = false
            try add(value)
        }
        let receipt = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(byteCount))
        try resources.charge(.projectedBytes, units: UInt64(byteCount))
        var output = ""
        output.reserveCapacity(byteCount)
        first = true
        func append(_ text: String) throws {
            var offset = 0
            for byte in text.utf8 {
                try resources.charge(.lexicalBytes, units: 1)
                if offset.isMultiple(of: 256) { try resources.checkCancellation() }
                output.append(Character(UnicodeScalar(byte)))
                offset += 1
            }
        }
        for value in values {
            if !first { try append(separator) }
            first = false
            try append(value)
        }
        try resources.checkCancellation()
        try profileStorage!.retain(output, reservation: receipt)
        return output
    }

    private mutating func decorated(_ prefix: String, _ text: String, _ suffix: String) throws -> String {
        var parts = SPICEParserBuffer<String>(resources: profileResources)
        try parts.append(prefix); try parts.append(text); try parts.append(suffix)
        return try joined(parts, separator: "")
    }

    private mutating func byteString(_ bytes: SPICEParserBuffer<UInt8>) throws -> String {
        guard let resources = profileResources else { preconditionFailure("Bounded byte text requires resources") }
        let receipt = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(bytes.count))
        try resources.charge(.projectedBytes, units: UInt64(bytes.count))
        var output = ""
        output.reserveCapacity(bytes.count)
        for byte in bytes {
            try resources.checkCancellation()
            try resources.charge(.lexicalBytes, units: 1)
            output.append(Character(UnicodeScalar(byte)))
        }
        try profileStorage!.retain(output, reservation: receipt)
        return output
    }

    private mutating func byteText(_ byte: UInt8) throws -> String {
        guard let resources = profileResources else { return String(UnicodeScalar(byte)) }
        let receipt = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: 1)
        let output = String(UnicodeScalar(byte))
        try profileStorage!.retain(output, reservation: receipt)
        return output
    }

    private mutating func characterText(_ character: Character) throws -> String {
        guard let resources = profileResources else { return String(character) }
        guard character.isASCII, let scalar = character.unicodeScalars.first,
              let byte = UInt8(exactly: scalar.value) else {
            throw SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode character formatting")
        }
        try resources.checkCancellation()
        return try byteText(byte)
    }

    private mutating func doubleText(_ value: Double) throws -> String {
        guard let resources = profileResources else { return String(value) }
        // Verified fixed Swift Float64 formatter extent; copy into exact retained text.
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: 64)
        let formattedText = try resources.reserveStorage(kind: .temporaryBytes, byteCount: 64)
        defer { withExtendedLifetime((scratch, formattedText)) {} }
        try resources.checkCancellation()
        try resources.charge(.projectedBytes, units: 64)
        let output = String(value)
        guard output.utf8.count <= 64 else { throw SPICEBoundedSourceError.unsupportedBudgetCapability("Double formatting backend extent") }
        return try profileStorage!.copyText(output)
    }

    private mutating func integerText(_ value: Double) throws -> String {
        guard let resources = profileResources else { return String(Int(value)) }
        guard value.isFinite, let integer = Int(exactly: value.rounded(.towardZero)) else {
            throw ParserDiagnostic.error("Numeric node is outside the representable integer range", at: currentLocation)
        }
        // Decimal digits of a signed Int plus its sign, derived from the fixed integer width.
        let maximumBytes = (Int.bitWidth * 30103 + 99999) / 100000 + 1
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: UInt64(maximumBytes))
        defer { withExtendedLifetime(scratch) {} }
        try resources.checkCancellation()
        try resources.charge(.projectedBytes, units: UInt64(maximumBytes))
        return try profileStorage!.copyText(String(integer))
    }

    private mutating func decodedQuotedText(_ text: String) throws -> String {
        guard let resources = profileResources else { return SPICELexer.decodeQuotedText(text, delimiter: "'") }
        var bytes = SPICEParserBuffer<UInt8>(resources: profileResources)
        for byte in text.utf8 {
            try resources.charge(.lexicalBytes, units: 1)
            try resources.checkCancellation()
            guard byte < 128 else { throw SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode quoted text decoding") }
            try bytes.append(byte)
        }
        var count = 0
        var index = 0
        while index < bytes.count {
            try resources.checkCancellation()
            try resources.charge(.lexicalBytes, units: 1)
            if bytes[index] == 92, index + 1 < bytes.count, bytes[index + 1] == 39 || bytes[index + 1] == 92 { index += 1 }
            count += 1; index += 1
        }
        let receipt = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: UInt64(count))
        try resources.charge(.projectedBytes, units: UInt64(count))
        var output = ""
        output.reserveCapacity(count)
        index = 0
        while index < bytes.count {
            try resources.checkCancellation()
            try resources.charge(.lexicalBytes, units: 1)
            if bytes[index] == 92, index + 1 < bytes.count, bytes[index + 1] == 39 || bytes[index + 1] == 92 { index += 1 }
            output.append(Character(UnicodeScalar(bytes[index])))
            index += 1
        }
        try profileStorage!.retain(output, reservation: receipt)
        return output
    }

    private mutating func fixedStrings(count: Int, _ build: () -> [String]) throws -> [String] {
        guard let resources = profileResources else { return build() }
        let receipt = try SPICESourceCapacity.reserve(of: String.self, capacity: count, kind: .liveOwnedBytes, resources: resources)
        let values = build()
        precondition(values.count == count)
        try profileStorage!.retain(values, reservation: receipt)
        return values
    }

    private mutating func identifierExpression(_ name: String) throws -> ParsedExpression {
        guard profileStorage != nil else { return .identifier(name) }
        let receipt = try profileStorage!.reservePayload(of: String.self)
        let expression = ParsedExpression.identifier(name)
        try profileStorage!.retain(expression, reservation: receipt)
        return expression
    }

    private mutating func negatedIdentifierExpression(_ name: String) throws -> ParsedExpression {
        let identifier = try identifierExpression(name)
        guard profileStorage != nil else { return .unaryOperation(.negate, identifier) }
        let receipt = try profileStorage!.reservePayload(of: (UnaryOperator, ParsedExpression).self)
        let expression = ParsedExpression.unaryOperation(.negate, identifier)
        try profileStorage!.retain(expression, reservation: receipt)
        return expression
    }

    private mutating func boundedTokenEvidence(_ token: SPICEToken) throws -> String {
        switch token {
        case .dotOperator(let name): return try decorated(".", name, ".")
        case .dottedLiteral(let text): return text
        case .equals: return "="
        case .comma: return ","
        case .leftParen: return "("
        case .rightParen: return ")"
        case .leftBrace: return "{"
        case .rightBrace: return "}"
        case .plus, .continuation: return "+"
        case .minus: return "-"
        case .asterisk: return "*"
        case .slash: return "/"
        case .caret: return "^"
        case .percent: return "%"
        case .lessThan: return "<"
        case .greaterThan: return ">"
        case .exclamation: return "!"
        case .ampersand: return "&"
        case .pipe: return "|"
        case .question: return "?"
        case .colon: return ":"
        case .semicolon: return ";"
        case .newline: return "newline"
        case .endOfFile: return "EOF"
        case .unterminatedQuote: return "unterminated quote"
        default: throw SPICEBoundedSourceError.unsupportedBudgetCapability("Bounded token evidence role")
        }
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

    private mutating func currentParameterStart() throws -> Bool { try isParameterStart(at: current) }

    private mutating func isParameterStart(at index: Int) throws -> Bool {
        try profileResources?.charge(.tokens, units: 1)
        try profileResources?.checkCancellation()
        guard index < tokens.count else {
            return false
        }
        if case .identifier(let id) = tokens[index].token {
            if index + 1 < tokens.count, case .equals = tokens[index + 1].token {
                return true
            }
            if try isParamsKeyword(id) {
                return true
            }
        }
        return false
    }

    private mutating func isParamsKeyword(_ id: String) throws -> Bool {
        let lower = try normalized(id)
        return lower == "params" || lower == "params:"
    }

    private mutating func remainingPositionalFieldCountBeforeParameterStart() throws -> Int {
        var index = current
        var fieldCount = 0
        while index < tokens.count {
            try profileResources?.charge(.tokens, units: 1)
            try profileResources?.checkCancellation()
            let token = tokens[index].token
            if try isLineEnd(token) || isParameterStart(at: index) {
                break
            }
            fieldCount += 1
            index = try positionalFieldEndIndex(startingAt: index)
        }
        return fieldCount
    }

    private mutating func currentControlledElementUsesExplicitSenseTerminals() throws -> Bool {
        let remainingFields = try remainingPositionalFieldCountBeforeParameterStart()
        if remainingFields >= 2 {
            return true
        }
        guard remainingFields == 1 else {
            return false
        }
        let afterCandidateSenseNode = try positionalFieldEndIndex(startingAt: current)
        return try isParameterStart(at: afterCandidateSenseNode)
    }

    private mutating func positionalFieldEndIndex(startingAt start: Int) throws -> Int {
        try profileResources?.charge(.tokens, units: 1)
        try profileResources?.checkCancellation()
        guard start < tokens.count else {
            return start
        }
        switch tokens[start].token {
        case .leftBrace:
            var index = start + 1
            var depth = 1
            while index < tokens.count, depth > 0 {
                try profileResources?.charge(.tokens, units: 1)
                try profileResources?.checkCancellation()
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

    private mutating func advance() throws {
        try profileResources?.charge(.tokens, units: 1)
        try profileResources?.checkCancellation()
        if current < tokens.count {
            current += 1
        }
    }

    private mutating func skipNewlinesAndComments() throws {
        while !isAtEnd {
            switch currentToken {
            case .newline, .comment, .continuation:
                try advance()
            default:
                return
            }
        }
    }

    private mutating func skipToEndOfLine() throws {
        while !isAtEnd && !isNewline {
            try advance()
        }
        if isNewline {
            try advance()
        }
    }

    private mutating func synchronize() throws {
        // Skip to next line on error
        while !isAtEnd && !isNewline {
            try advance()
        }
        if isNewline {
            try advance()
        }
    }
}

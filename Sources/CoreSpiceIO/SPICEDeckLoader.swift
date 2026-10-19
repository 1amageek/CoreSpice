import CircuiteFoundation
import CoreSpiceParsedIR
import CoreSpiceParser
import CoreSpiceParserSPICE
import Foundation

/// A captured, parsed source graph admitted for actual selected lowering.
/// Successful loading does not establish numerical model/component capability.
public struct LoadedSPICEDeck: Sendable {
    private let retainedOwner: (any Sendable)?
    public let exactRequest: SPICEExactLoadRequest?
    public let exactSources: [SPICEExactSourceBinding]
    public let sourceWorkConsumption: [SPICESourceWorkKind: UInt64]
    public var inputReferences: [ArtifactReference] { exactSources.map(\.reference) }
    public var dependencyEvents: [SPICESourceDependencyEvent] { netlist.dependencyEvents }
    public let source: String
    public let netlist: ParsedNetlist
    public let coverage: SPICEDeckCoverageReport
    public let captures: [SPICESourceCapture]
    public let capturePolicy: SPICESourceCapturePolicy
    public var inputPaths: [String] { captures.compactMap(\.resolvedPath) }
    public var modelOrigins: [String: ParsedModelOrigin] {
        func collect(models: [ParsedModel], subcircuits: [ParsedSubcircuit],
                     into result: inout [String: ParsedModelOrigin]) {
            for model in models {
                if let origin = model.origin { result[origin.declarationID] = origin }
            }
            for subcircuit in subcircuits {
                collect(models: subcircuit.body.models, subcircuits: subcircuit.body.subcircuits, into: &result)
            }
        }
        var result: [String: ParsedModelOrigin] = [:]
        collect(models: netlist.models, subcircuits: netlist.subcircuits, into: &result)
        return result
    }

    init(
        source: String,
        netlist: ParsedNetlist,
        coverage: SPICEDeckCoverageReport,
        captures: [SPICESourceCapture],
        capturePolicy: SPICESourceCapturePolicy,
        exactRequest: SPICEExactLoadRequest? = nil,
        exactSources: [SPICEExactSourceBinding] = [],
        sourceWorkConsumption: [SPICESourceWorkKind: UInt64] = [:],
        retainedOwner: (any Sendable)? = nil
    ) {
        self.exactRequest = exactRequest
        self.retainedOwner = retainedOwner
        self.exactSources = exactSources
        self.sourceWorkConsumption = sourceWorkConsumption
        self.source = source
        self.netlist = netlist
        self.coverage = coverage
        self.captures = captures
        self.capturePolicy = capturePolicy
    }
}

/// Failures raised before a parsed deck can enter the execution pipeline.
public enum SPICEDeckLoadError: Error, Sendable {
    case fileRead(path: String, reason: String)
    case blockedExecutionIntent(items: [SPICEDeckCoverageItem])
}

extension SPICEDeckLoadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileRead(let path, let reason):
            return "Failed to read SPICE deck '\(path)': \(reason)"
        case .blockedExecutionIntent(let items):
            let names = items.map(\.name).joined(separator: ", ")
            return "SPICE deck contains execution-blocking intent: \(names)"
        }
    }
}

/// Loads SPICE decks through the production include-resolution and coverage gate.
///
/// This type owns filesystem expansion only. Parsing remains in
/// `CoreSpiceParserSPICE`, while lowering and device binding remain in their
/// respective execution layers.
public enum SPICEDeckLoader {

    /// Loads local sources through the owned grammar with pre-read resource admission.
    public static func loadFile(at path: String, includePaths: [String] = [],
        capturePolicy: SPICESourceCapturePolicy, resources: any SPICESourceResourceAccounting,
        sourceReader: any SPICESourceReading = LocalSPICESourceReader()) async throws -> LoadedSPICEDeck {
        let configuration = ParserConfiguration(resolveIncludes: true, includePaths: includePaths)
        let resolver = SPICEAccountedFileResolver(includePaths: includePaths, policy: capturePolicy,
            reader: sourceReader, resources: resources)
        let root = try await resolver.root(at: canonicalPath(path))
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "CoreSpice.local-file-profile.v1",
            configuration: configuration, resources: resources, maximumPageByteCount: capturePolicy.maximumPageByteCount)
        let parsed = try await SPICEParser().parseProfile(document: root, configuration: configuration,
            environment: environment, resolver: resolver, resources: resources)
        let coverageLease = try await resolver.reserveCoverage(parsed.netlist)
        let coverage = SPICEDeckCoverageReport.generate(from: parsed.netlist)
        let blocked = coverage.globalExecutionBlockers
        guard blocked.isEmpty else { throw SPICEDeckLoadError.blockedExecutionIntent(items: blocked) }
        let captures = try await resolver.capturedSources()
        try resources.checkCancellation()
        return LoadedSPICEDeck(source: root.text, netlist: parsed.netlist, coverage: coverage,
            captures: captures, capturePolicy: capturePolicy, retainedOwner: (parsed, resolver, coverageLease))
    }

    /// Loads a deck file and resolves every nested `.include` and `.lib`.
    public static func loadFile(
        at path: String,
        includePaths: [String] = [],
        capturePolicy: SPICESourceCapturePolicy = .hostDefault,
        sourceReader: any SPICESourceReading = LocalSPICESourceReader()
    ) async throws -> LoadedSPICEDeck {
        let rootPath = canonicalPath(path)
        let resolver = SPICECapturingFileResolver(includePaths: includePaths, policy: capturePolicy, reader: sourceReader)
        let document: SPICESourceDocument
        do {
            document = try await resolver.readFile(at: rootPath)
        } catch let error as SPICESourceCaptureError {
            throw error
        } catch {
            throw SPICEDeckLoadError.fileRead(
                path: rootPath,
                reason: String(describing: error)
            )
        }
        return try await load(
            document: document,
            includePaths: includePaths,
            resolver: resolver
        )
    }

    /// Loads in-memory source using the same execution gate as file-backed decks.
    public static func load(
        source: String,
        fileName: String? = nil,
        includePaths: [String] = [],
        capturePolicy: SPICESourceCapturePolicy = .hostDefault,
        sourceReader: any SPICESourceReading = LocalSPICESourceReader()
    ) async throws -> LoadedSPICEDeck {
        let resolver = SPICECapturingFileResolver(includePaths: includePaths, policy: capturePolicy, reader: sourceReader)
        let document = try await resolver.captureMemory(source, fileName: fileName)
        return try await load(document: document, includePaths: includePaths, resolver: resolver)
    }

    private static func load(
        document: SPICESourceDocument,
        includePaths: [String],
        resolver: SPICECapturingFileResolver
    ) async throws -> LoadedSPICEDeck {
        let configuration = ParserConfiguration(
            resolveIncludes: true,
            includePaths: includePaths
        )
        let parser = SPICEParser()
        let parseResult = await parser.parse(
            document: document,
            configuration: configuration,
            fileResolver: resolver
        )
        if let failure = await resolver.captureFailure() { throw failure }
        let netlist = try parseResult.get()
        let coverage = SPICEDeckCoverageReport.generate(from: parseResult)
        let blocked = coverage.globalExecutionBlockers
        guard blocked.isEmpty else {
            throw SPICEDeckLoadError.blockedExecutionIntent(items: blocked)
        }
        return LoadedSPICEDeck(
            source: document.text,
            netlist: netlist,
            coverage: coverage,
            captures: await resolver.capturedSources(),
            capturePolicy: resolver.policy
        )
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

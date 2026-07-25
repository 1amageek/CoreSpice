import CoreSpiceParsedIR
import CoreSpiceParser
import CoreSpiceParserSPICE
import Foundation

/// A fully resolved SPICE deck that is safe to pass to lowering and execution.
public struct LoadedSPICEDeck: Sendable {
    public let source: String
    public let netlist: ParsedNetlist
    public let coverage: SPICEDeckCoverageReport
    public let inputPaths: [String]

    public init(
        source: String,
        netlist: ParsedNetlist,
        coverage: SPICEDeckCoverageReport,
        inputPaths: [String]
    ) {
        self.source = source
        self.netlist = netlist
        self.coverage = coverage
        self.inputPaths = inputPaths
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

    /// Loads a deck file and resolves every nested `.include` and `.lib`.
    public static func loadFile(
        at path: String,
        includePaths: [String] = []
    ) async throws -> LoadedSPICEDeck {
        let rootPath = canonicalPath(path)
        let resolver = RecordingFileResolver(
            base: LocalFileResolver(searchPaths: includePaths)
        )
        let source: String
        do {
            source = try await resolver.readFile(at: rootPath)
        } catch {
            throw SPICEDeckLoadError.fileRead(
                path: rootPath,
                reason: String(describing: error)
            )
        }
        return try await load(
            source: source,
            fileName: rootPath,
            includePaths: includePaths,
            resolver: resolver
        )
    }

    /// Loads in-memory source using the same execution gate as file-backed decks.
    public static func load(
        source: String,
        fileName: String? = nil,
        includePaths: [String] = []
    ) async throws -> LoadedSPICEDeck {
        let resolver = RecordingFileResolver(
            base: LocalFileResolver(searchPaths: includePaths)
        )
        if let fileName {
            await resolver.record(canonicalPath(fileName))
        }
        return try await load(
            source: source,
            fileName: fileName.map(canonicalPath),
            includePaths: includePaths,
            resolver: resolver
        )
    }

    private static func load(
        source: String,
        fileName: String?,
        includePaths: [String],
        resolver: RecordingFileResolver
    ) async throws -> LoadedSPICEDeck {
        let configuration = ParserConfiguration(
            resolveIncludes: true,
            includePaths: includePaths
        )
        let parser = SPICEParser()
        let parseResult = await parser.parse(
            source: source,
            fileName: fileName,
            configuration: configuration,
            fileResolver: resolver
        )
        let netlist = try parseResult.get()
        let coverage = SPICEDeckCoverageReport.generate(from: parseResult)
        let blocked = coverage.items.filter { $0.status == .blocked }
        guard blocked.isEmpty else {
            throw SPICEDeckLoadError.blockedExecutionIntent(items: blocked)
        }
        return LoadedSPICEDeck(
            source: source,
            netlist: netlist,
            coverage: coverage,
            inputPaths: await resolver.recordedPaths()
        )
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}

private actor RecordingFileResolver: ResolvedPathProvidingFileResolver {
    private let base: LocalFileResolver
    private var paths: [String] = []
    private var pathSet: Set<String> = []

    init(base: LocalFileResolver) {
        self.base = base
    }

    func resolveInclude(path: String, relativeTo: String?) async throws -> String {
        let resolved = try await resolvedPath(for: path, relativeTo: relativeTo)
        return try await readFile(at: resolved)
    }

    func resolveLibrary(
        path: String,
        section: String?,
        relativeTo: String?
    ) async throws -> String {
        let resolved = try await resolvedPath(for: path, relativeTo: relativeTo)
        return try await base.resolveLibrary(
            path: resolved,
            section: section,
            relativeTo: nil
        )
    }

    func readFile(at path: String) async throws -> String {
        record(path)
        return try await base.readFile(at: path)
    }

    func resolvedPath(for path: String, relativeTo: String?) async throws -> String {
        let resolved = try await base.resolvedPath(for: path, relativeTo: relativeTo)
        record(resolved)
        return resolved
    }

    func record(_ path: String) {
        let canonical = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        if pathSet.insert(canonical).inserted {
            paths.append(canonical)
        }
    }

    func recordedPaths() -> [String] {
        paths
    }
}

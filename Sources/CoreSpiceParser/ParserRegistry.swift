import CoreSpiceParsedIR
import Synchronization

/// A registry for netlist parsers.
///
/// The parser registry maintains a collection of available parsers
/// and provides methods for selecting the appropriate parser based
/// on file extension or content auto-detection.
public final class ParserRegistry: Sendable {

    /// The registered parsers.
    private let parsers: Mutex<[String: any NetlistParser]>

    /// Creates an empty registry.
    public init() {
        self.parsers = Mutex([:])
    }

    /// Creates a registry with the given parsers.
    public init(parsers: [any NetlistParser]) {
        var dict: [String: any NetlistParser] = [:]
        for parser in parsers {
            dict[parser.formatIdentifier] = parser
        }
        self.parsers = Mutex(dict)
    }

    /// Registers a parser.
    ///
    /// - Parameter parser: The parser to register.
    public func register(_ parser: any NetlistParser) {
        parsers.withLock { dict in
            dict[parser.formatIdentifier] = parser
        }
    }

    /// Returns the parser for the given format identifier.
    ///
    /// - Parameter identifier: The format identifier (e.g., "spice").
    /// - Returns: The registered parser, or nil if not found.
    public func parser(for identifier: String) -> (any NetlistParser)? {
        parsers.withLock { dict in
            dict[identifier]
        }
    }

    /// Returns the parser for a file path based on extension.
    ///
    /// - Parameter path: The file path.
    /// - Returns: The matching parser, or nil if none match.
    public func parser(forPath path: String) -> (any NetlistParser)? {
        parsers.withLock { dict in
            for parser in dict.values {
                if parser.matchesExtension(path) {
                    return parser
                }
            }
            return nil
        }
    }

    /// Auto-detects and returns the appropriate parser for the source.
    ///
    /// - Parameter source: The source text to parse.
    /// - Returns: The detected parser, or nil if detection fails.
    public func detectParser(for source: String) -> (any NetlistParser)? {
        parsers.withLock { dict in
            for parser in dict.values {
                if parser.canParse(source: source) {
                    return parser
                }
            }
            return nil
        }
    }

    /// Returns all registered parsers.
    public var allParsers: [any NetlistParser] {
        parsers.withLock { dict in
            Array(dict.values)
        }
    }

    /// Returns all registered format identifiers.
    public var registeredFormats: [String] {
        parsers.withLock { dict in
            Array(dict.keys).sorted()
        }
    }

    // MARK: - Convenience Parsing Methods

    /// Parses a source string using auto-detection or the specified format.
    ///
    /// - Parameters:
    ///   - source: The source text to parse.
    ///   - format: The format identifier, or nil for auto-detection.
    ///   - fileName: The file name for diagnostics.
    ///   - configuration: Parser configuration.
    ///   - fileResolver: File resolver for includes.
    /// - Returns: The parse result.
    public func parse(
        source: String,
        format: String? = nil,
        fileName: String? = nil,
        configuration: ParserConfiguration = .default,
        fileResolver: any FileResolver = NullFileResolver()
    ) async -> ParseResult {
        let selectedParser: (any NetlistParser)?

        if let format = format {
            selectedParser = parser(for: format)
        } else {
            selectedParser = detectParser(for: source)
        }

        guard let parser = selectedParser else {
            return ParseResult(errors: [
                .error("No parser available for the given format or content")
            ])
        }

        return await parser.parse(
            source: source,
            fileName: fileName,
            configuration: configuration,
            fileResolver: fileResolver
        )
    }

    /// Parses a file at the given path.
    ///
    /// - Parameters:
    ///   - path: The file path.
    ///   - format: The format identifier, or nil for auto-detection.
    ///   - configuration: Parser configuration.
    ///   - fileResolver: File resolver for includes.
    /// - Returns: The parse result.
    public func parseFile(
        at path: String,
        format: String? = nil,
        configuration: ParserConfiguration = .default,
        fileResolver: (any FileResolver)? = nil
    ) async -> ParseResult {
        let resolver = fileResolver ?? LocalFileResolver()

        do {
            let source = try await resolver.readFile(at: path)
            let selectedFormat = format ?? {
                if let p = parser(forPath: path) {
                    return p.formatIdentifier
                }
                return nil
            }()

            return await parse(
                source: source,
                format: selectedFormat,
                fileName: path,
                configuration: configuration,
                fileResolver: resolver
            )
        } catch {
            return ParseResult(errors: [
                .error("Failed to read file: \(error)")
            ])
        }
    }
}

import CoreSpiceParsedIR
import Foundation

/// A protocol for netlist parsers.
///
/// Netlist parsers convert source text into a `ParsedNetlist`
/// intermediate representation. Different implementations handle
/// different netlist formats (SPICE, Spectre, etc.).
public protocol NetlistParser: Sendable {

    /// A unique identifier for this parser format (e.g., "spice", "spectre").
    var formatIdentifier: String { get }

    /// File extensions typically associated with this format.
    var fileExtensions: [String] { get }

    /// A human-readable name for this format.
    var formatName: String { get }

    /// Parses the source text into a netlist.
    ///
    /// - Parameters:
    ///   - source: The source text to parse.
    ///   - fileName: The name of the file being parsed (for diagnostics).
    ///   - configuration: Parser configuration options.
    ///   - fileResolver: Resolver for handling include directives.
    /// - Returns: The parse result containing the netlist or diagnostics.
    func parse(
        source: String,
        fileName: String?,
        configuration: ParserConfiguration,
        fileResolver: any FileResolver
    ) async -> ParseResult

    /// Checks if this parser can likely parse the given source.
    ///
    /// Used for auto-detection of netlist format.
    ///
    /// - Parameter source: The source text to check.
    /// - Returns: True if this parser can likely handle the source.
    func canParse(source: String) -> Bool
}

extension NetlistParser {

    /// Parses with default configuration and null file resolver.
    public func parse(source: String, fileName: String? = nil) async -> ParseResult {
        await parse(
            source: source,
            fileName: fileName,
            configuration: .default,
            fileResolver: NullFileResolver()
        )
    }

    /// Checks if the file extension matches this parser.
    public func matchesExtension(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return fileExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .contains(ext)
    }
}

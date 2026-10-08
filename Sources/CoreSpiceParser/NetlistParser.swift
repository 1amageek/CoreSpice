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

    /// Parses one resolved source document into a netlist.
    ///
    /// - Parameters:
    ///   - document: Text, chosen diagnostic path and available captured identity.
    ///   - configuration: Parser configuration options.
    ///   - fileResolver: Resolver for handling include directives.
    /// - Returns: The parse result containing the netlist or diagnostics.
    func parse(
        document: SPICESourceDocument,
        configuration: ParserConfiguration,
        fileResolver: any FileResolver
    ) async -> ParseResult

    /// Parses caller-owned uncaptured text through the same document contract.
    func parse(source: String, fileName: String?, configuration: ParserConfiguration,
               fileResolver: any FileResolver) async -> ParseResult

    /// Checks if this parser can likely parse the given source.
    ///
    /// Used for auto-detection of netlist format.
    ///
    /// - Parameter source: The source text to check.
    /// - Returns: True if this parser can likely handle the source.
    func canParse(source: String) -> Bool
}

extension NetlistParser {

    /// Parses uncaptured text. Its filename is diagnostic metadata, not content identity.
    public func parse(source: String, fileName: String? = nil,
                      configuration: ParserConfiguration = .default,
                      fileResolver: any FileResolver = NullFileResolver()) async -> ParseResult {
        await parse(document: SPICESourceDocument(text: source, resolvedPath: fileName),
                    configuration: configuration, fileResolver: fileResolver)
    }

    /// Checks if the file extension matches this parser.
    public func matchesExtension(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return fileExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .contains(ext)
    }
}

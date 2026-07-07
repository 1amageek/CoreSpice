import CoreSpiceParsedIR

/// The result of parsing a netlist.
///
/// Contains either a successfully parsed netlist or
/// diagnostics explaining why parsing failed.
public struct ParseResult: Sendable {

    /// The parsed netlist, if parsing succeeded.
    public let netlist: ParsedNetlist?

    /// All diagnostics generated during parsing.
    public let diagnostics: [ParserDiagnostic]

    /// Whether parsing completed successfully.
    public var isSuccess: Bool {
        netlist != nil && !hasErrors
    }

    /// Whether any errors were reported.
    public var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }

    /// Whether any warnings were reported.
    public var hasWarnings: Bool {
        diagnostics.contains { $0.severity == .warning }
    }

    /// Only the error diagnostics.
    public var errors: [ParserDiagnostic] {
        diagnostics.filter { $0.severity == .error }
    }

    /// Only the warning diagnostics.
    public var warnings: [ParserDiagnostic] {
        diagnostics.filter { $0.severity == .warning }
    }

    /// Creates a successful parse result.
    public init(
        netlist: ParsedNetlist,
        diagnostics: [ParserDiagnostic] = []
    ) {
        self.netlist = netlist
        self.diagnostics = diagnostics
    }

    /// Creates a failed parse result.
    public init(errors: [ParserDiagnostic]) {
        self.netlist = nil
        self.diagnostics = errors
    }

    /// Returns the netlist or throws the first error.
    public func get() throws -> ParsedNetlist {
        if let firstError = errors.first {
            throw firstError
        }
        if let netlist = netlist {
            return netlist
        }
        throw ParserDiagnostic.error("Unknown parse error")
    }

    /// Returns the partial netlist even when parser error diagnostics exist.
    ///
    /// This is only for diagnostic tooling that needs to inspect the recoverable
    /// parser state. Execution paths should use `get()` so malformed decks fail
    /// before lowering or simulation.
    public func getAllowingErrors() throws -> ParsedNetlist {
        if let netlist = netlist {
            return netlist
        }
        if let firstError = errors.first {
            throw firstError
        }
        throw ParserDiagnostic.error("Unknown parse error")
    }
}

extension ParseResult: CustomStringConvertible {
    public var description: String {
        if isSuccess {
            var result = "Parse succeeded"
            if !warnings.isEmpty {
                result += " with \(warnings.count) warning(s)"
            }
            return result
        } else {
            return "Parse failed with \(errors.count) error(s)"
        }
    }
}

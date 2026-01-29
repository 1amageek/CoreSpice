import CoreSpiceParsedIR

/// A diagnostic message from the parser.
///
/// Diagnostics report errors, warnings, and informational messages
/// encountered during parsing, with source location information for
/// IDE integration and error reporting.
public struct ParserDiagnostic: Sendable, Error {

    /// The severity of this diagnostic.
    public let severity: DiagnosticSeverity

    /// The diagnostic message.
    public let message: String

    /// The source location where the issue was detected.
    public let location: SourceLocation?

    /// The source range if applicable.
    public let range: SourceRange?

    /// Optional fix-it suggestions.
    public let fixIts: [FixIt]

    /// Related notes providing additional context.
    public let notes: [ParserNote]

    public init(
        severity: DiagnosticSeverity,
        message: String,
        location: SourceLocation? = nil,
        range: SourceRange? = nil,
        fixIts: [FixIt] = [],
        notes: [ParserNote] = []
    ) {
        self.severity = severity
        self.message = message
        self.location = location
        self.range = range
        self.fixIts = fixIts
        self.notes = notes
    }

    /// Creates an error diagnostic.
    public static func error(
        _ message: String,
        at location: SourceLocation? = nil
    ) -> ParserDiagnostic {
        ParserDiagnostic(severity: .error, message: message, location: location)
    }

    /// Creates a warning diagnostic.
    public static func warning(
        _ message: String,
        at location: SourceLocation? = nil
    ) -> ParserDiagnostic {
        ParserDiagnostic(severity: .warning, message: message, location: location)
    }

    /// Creates an info diagnostic.
    public static func info(
        _ message: String,
        at location: SourceLocation? = nil
    ) -> ParserDiagnostic {
        ParserDiagnostic(severity: .info, message: message, location: location)
    }
}

/// A fix-it suggestion for automatically correcting an issue.
public struct FixIt: Sendable {

    /// Description of the fix.
    public let message: String

    /// The range to replace.
    public let range: SourceRange

    /// The replacement text.
    public let replacement: String

    public init(message: String, range: SourceRange, replacement: String) {
        self.message = message
        self.range = range
        self.replacement = replacement
    }
}

/// A note providing additional context for a diagnostic.
public struct ParserNote: Sendable {

    /// The note message.
    public let message: String

    /// The location this note refers to.
    public let location: SourceLocation?

    public init(message: String, location: SourceLocation? = nil) {
        self.message = message
        self.location = location
    }
}

extension ParserDiagnostic: CustomStringConvertible {
    public var description: String {
        var result = ""
        if let loc = location {
            result += "\(loc): "
        }
        result += "\(severity.rawValue): \(message)"
        for note in notes {
            result += "\n  note: \(note.message)"
            if let noteLoc = note.location {
                result += " at \(noteLoc)"
            }
        }
        return result
    }
}

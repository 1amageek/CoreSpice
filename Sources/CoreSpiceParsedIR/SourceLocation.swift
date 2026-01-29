/// A position in source code for diagnostic reporting.
///
/// Captures the file name, line number, and column to provide
/// precise error location information during parsing.
public struct SourceLocation: Sendable, Hashable, Codable {

    /// The file name or identifier where this location occurs.
    public let file: String

    /// The line number (1-indexed).
    public let line: Int

    /// The column number (1-indexed).
    public let column: Int

    public init(file: String, line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }

    /// Creates a location with unknown file origin.
    public static func unknown(line: Int, column: Int) -> SourceLocation {
        SourceLocation(file: "<unknown>", line: line, column: column)
    }
}

extension SourceLocation: CustomStringConvertible {
    public var description: String {
        "\(file):\(line):\(column)"
    }
}

/// A range in source code spanning from a start to an end location.
public struct SourceRange: Sendable, Hashable, Codable {

    /// The starting location of the range.
    public let start: SourceLocation

    /// The ending location of the range.
    public let end: SourceLocation

    public init(start: SourceLocation, end: SourceLocation) {
        self.start = start
        self.end = end
    }

    /// Creates a zero-width range at a single location.
    public init(at location: SourceLocation) {
        self.start = location
        self.end = location
    }
}

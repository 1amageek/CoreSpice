import CoreSpiceParsedIR

/// Options for serializing netlists back to text.
public struct SerializerOptions: Sendable {

    /// Whether to include comments and whitespace formatting.
    public var prettyPrint: Bool

    /// The line width target for wrapping.
    public var lineWidth: Int

    /// The indentation string to use.
    public var indentation: String

    /// Whether to sort components by name.
    public var sortComponents: Bool

    /// Whether to include the title line.
    public var includeTitle: Bool

    /// Whether to include the .end directive.
    public var includeEnd: Bool

    /// Number format for parameter values.
    public var numberFormat: NumberFormat

    public enum NumberFormat: Sendable {
        /// Engineering notation with SI prefixes (1k, 1M, 1u).
        case engineering

        /// Scientific notation (1e3, 1e6, 1e-6).
        case scientific

        /// Fixed decimal (1000, 1000000, 0.000001).
        case fixed(precision: Int)
    }

    public init(
        prettyPrint: Bool = true,
        lineWidth: Int = 80,
        indentation: String = "  ",
        sortComponents: Bool = false,
        includeTitle: Bool = true,
        includeEnd: Bool = true,
        numberFormat: NumberFormat = .engineering
    ) {
        self.prettyPrint = prettyPrint
        self.lineWidth = lineWidth
        self.indentation = indentation
        self.sortComponents = sortComponents
        self.includeTitle = includeTitle
        self.includeEnd = includeEnd
        self.numberFormat = numberFormat
    }

    /// Default serialization options.
    public static let `default` = SerializerOptions()

    /// Compact output without extra whitespace.
    public static let compact = SerializerOptions(
        prettyPrint: false,
        sortComponents: false
    )
}

/// A protocol for serializing parsed netlists back to text.
///
/// Serializers convert a `ParsedNetlist` back into source text,
/// enabling round-trip editing and format conversion.
public protocol NetlistSerializer: Sendable {

    /// The format identifier this serializer outputs.
    var formatIdentifier: String { get }

    /// Serializes a netlist to text.
    ///
    /// - Parameters:
    ///   - netlist: The netlist to serialize.
    ///   - options: Serialization options.
    /// - Returns: The serialized text.
    func serialize(
        _ netlist: ParsedNetlist,
        options: SerializerOptions
    ) -> String
}

extension NetlistSerializer {

    /// Serializes with default options.
    public func serialize(_ netlist: ParsedNetlist) -> String {
        serialize(netlist, options: .default)
    }
}

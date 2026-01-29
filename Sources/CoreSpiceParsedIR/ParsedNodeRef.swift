/// A reference to a circuit node as parsed from source.
///
/// Node references can be named (e.g., "vdd", "out") or numbered (e.g., "0", "1").
/// The ground node is typically referenced as "0" or "gnd".
public struct ParsedNodeRef: Sendable, Hashable {

    /// The node name as it appears in the source.
    public let name: String

    /// The source location where this reference appears.
    public let location: SourceLocation?

    public init(name: String, location: SourceLocation? = nil) {
        self.name = name
        self.location = location
    }

    /// Returns true if this references the ground node.
    public var isGround: Bool {
        name == "0" || name.lowercased() == "gnd"
    }
}

extension ParsedNodeRef: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(name: value)
    }
}

extension ParsedNodeRef: CustomStringConvertible {
    public var description: String {
        name
    }
}

/// Invocation-local traversal identity, independent of immutable source content.
public struct SPICEParseOccurrenceID: Sendable, Hashable {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
}

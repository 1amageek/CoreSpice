/// Source-level evidence emitted by SPICE deck preprocessing.
///
/// Preprocessing events are audit evidence only. They are not executable control
/// statements and are not serialized back into a flattened SPICE deck.
public struct SPICEPreprocessingEvent: Sendable, Hashable {

    /// The conditional directive kind.
    public let kind: SPICEConditionalDirectiveKind

    /// The directive expression, when the directive carries one.
    public let expression: String?

    /// Whether this branch was active after preprocessing.
    public let active: Bool

    /// The source location of the directive.
    public let location: SourceLocation?

    public init(
        kind: SPICEConditionalDirectiveKind,
        expression: String?,
        active: Bool,
        location: SourceLocation?
    ) {
        self.kind = kind
        self.expression = expression
        self.active = active
        self.location = location
    }
}

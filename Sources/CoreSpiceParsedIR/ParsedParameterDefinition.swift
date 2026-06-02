/// A source-level SPICE parameter definition.
///
/// `ParsedNetlist.parameters` is the canonical executable parameter environment.
/// This type preserves the ordered deck declaration and source location for
/// auditing, coverage reports, and faithful serialization.
public struct ParsedParameterDefinition: Sendable, Hashable {

    /// The parameter name as parsed from the source deck.
    public let name: String

    /// The parsed parameter expression.
    public let value: ParsedExpression

    /// The source location of the `.param` directive.
    public let location: SourceLocation?

    public init(
        name: String,
        value: ParsedExpression,
        location: SourceLocation? = nil
    ) {
        self.name = name
        self.value = value
        self.location = location
    }
}

/// A syntax diagnostic retaining only its required immutable source backing.
public struct SPICEProfileParseFailure: Error, Sendable {
    /// Raw diagnostic extraction transfers retention responsibility to its caller.
    public let diagnostic: ParserDiagnostic
    private let retainedOwner: any Sendable

    package init(diagnostic: ParserDiagnostic, retaining owner: any Sendable) {
        self.diagnostic = diagnostic
        self.retainedOwner = owner
    }
}

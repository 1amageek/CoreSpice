/// Aggregate counts for a SPICE deck coverage report.
public struct SPICEDeckCoverageSummary: Sendable, Hashable, Codable {

    public let totalItems: Int
    public let preservedItems: Int
    public let appliedItems: Int
    public let supportedItems: Int
    public let warningItems: Int
    public let blockedItems: Int
    public let parserDiagnostics: Int
    public let parserErrors: Int
    public let parserWarnings: Int

    public init(
        totalItems: Int,
        preservedItems: Int,
        appliedItems: Int,
        supportedItems: Int,
        warningItems: Int,
        blockedItems: Int,
        parserDiagnostics: Int,
        parserErrors: Int,
        parserWarnings: Int
    ) {
        self.totalItems = totalItems
        self.preservedItems = preservedItems
        self.appliedItems = appliedItems
        self.supportedItems = supportedItems
        self.warningItems = warningItems
        self.blockedItems = blockedItems
        self.parserDiagnostics = parserDiagnostics
        self.parserErrors = parserErrors
        self.parserWarnings = parserWarnings
    }
}

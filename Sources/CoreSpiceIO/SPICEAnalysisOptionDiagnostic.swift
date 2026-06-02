import CoreSpiceParsedIR

/// A non-fatal option diagnostic.
public struct SPICEAnalysisOptionDiagnostic: Sendable, Hashable {

    public let name: String
    public let valueDescription: String?
    public let message: String
    public let location: SourceLocation?

    public init(
        name: String,
        valueDescription: String?,
        message: String,
        location: SourceLocation?
    ) {
        self.name = name
        self.valueDescription = valueDescription
        self.message = message
        self.location = location
    }
}

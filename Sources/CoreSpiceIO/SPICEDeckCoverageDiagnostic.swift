import CoreSpiceParsedIR

/// Serializable diagnostic entry for SPICE deck coverage reports.
public struct SPICEDeckCoverageDiagnostic: Sendable, Hashable, Codable {

    public let severity: String
    public let message: String
    public let location: SourceLocation?

    public init(
        severity: String,
        message: String,
        location: SourceLocation? = nil
    ) {
        self.severity = severity
        self.message = message
        self.location = location
    }
}

/// Original model-check messages, including any original parameter adjustment.
public struct BSIM3Diagnostic: Sendable, Equatable {
    public enum Severity: Sendable { case information, warning, fatal }
    public let severity: Severity
    public let message: String

    init(_ message: String) {
        self.message = message
        self.severity = message.hasPrefix("Fatal:") ? .fatal
            : message.hasPrefix("Warning:") || message.contains("clamped") || message.contains("set to")
                ? .warning : .information
    }
}

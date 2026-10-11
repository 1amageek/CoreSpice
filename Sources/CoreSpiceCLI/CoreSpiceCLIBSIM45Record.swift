import CoreSpiceCompactModels

/// Completed phase evidence preserves the actual exact-release preparation implementation.
public struct CoreSpiceCLIBSIM45Record: Codable, Sendable, Hashable {
    public let phase: String
    public let device: String
    public let implementationIdentity: String
    public let diagnostics: [CoreSpiceCLIBSIM45Diagnostic]
    public init(phase: String, device: String, implementationIdentity: String, diagnostics: [BSIM45Diagnostic]) {
        self.phase = phase; self.device = device; self.implementationIdentity = implementationIdentity
        self.diagnostics = diagnostics.map { CoreSpiceCLIBSIM45Diagnostic($0) }
    }
}

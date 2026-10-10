import CoreSpiceCompactModels

/// A completed phase retains preparation diagnostics and immutable qualification limits.
public struct CoreSpiceCLIBSIM4Record: Codable, Sendable, Hashable {
    public let phase: String
    public let device: String
    public let diagnostics: [BSIM4Diagnostic]
    public let maintainerUnsupportedNoiseMode: Bool
    public init(phase: String, device: String, diagnostics: [BSIM4Diagnostic], maintainerUnsupportedNoiseMode: Bool) {
        self.phase = phase
        self.device = device
        self.diagnostics = diagnostics
        self.maintainerUnsupportedNoiseMode = maintainerUnsupportedNoiseMode
    }
}

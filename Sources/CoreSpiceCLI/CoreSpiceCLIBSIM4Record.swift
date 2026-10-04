import CoreSpiceCompactModels

/// Initial binding evidence preserves diagnostics and immutable qualification limits.
public struct CoreSpiceCLIBSIM4Record: Codable, Sendable, Hashable {
    public let phase: String
    public let device: String
    public let diagnostics: [BSIM4Diagnostic]
    public let maintainerUnsupportedNoiseMode: Bool
    public init(device: String, diagnostics: [BSIM4Diagnostic], maintainerUnsupportedNoiseMode: Bool) {
        phase = "initial_binding"
        self.device = device
        self.diagnostics = diagnostics
        self.maintainerUnsupportedNoiseMode = maintainerUnsupportedNoiseMode
    }
}

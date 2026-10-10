import CoreSpiceCompactModels

/// Initial binding diagnostics retained without the bound evaluator.
public struct NativeBSIM4PreparationRecord: Sendable {
    public let device: String
    public let diagnostics: [BSIM4Diagnostic]
    public let maintainerUnsupportedNoiseMode: Bool
}

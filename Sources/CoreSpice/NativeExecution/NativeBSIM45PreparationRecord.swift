import CoreSpiceCompactModels

/// Immutable exact-release diagnostics share safe-owner backing without executable authority.
public struct NativeBSIM45PreparationRecord: Sendable {
    public let device: String
    public let implementationIdentity: String
    public let diagnostics: [BSIM45Diagnostic]
}

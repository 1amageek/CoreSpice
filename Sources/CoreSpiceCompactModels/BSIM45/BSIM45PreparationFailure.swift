/// Original bounded preparation diagnostics survive destruction of a failed owner.
public struct BSIM45PreparationFailure: Error, Sendable, CustomStringConvertible {
    public let reason: BSIM45Error
    public let diagnostics: [BSIM45Diagnostic]
    public var description: String { "BSIM45 preparation: \(reason); diagnostics: \(diagnostics)" }
}

/// Bounded original diagnostic provenance; no later-release warning is substituted.
public struct BSIM45Diagnostic: Sendable, Equatable {
    public let code: UInt32
    public let role: Int32
    public let parameterID: Int32
    public let sourceSite: UInt32
    public let value: Double
    public let text: String
}

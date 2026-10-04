/// Context-local original diagnostic with a stable code for the maintainer limitation.
public struct BSIM4Diagnostic: Sendable, Hashable, Codable {
    public enum Code: String, Sendable, Codable { case originalModelMessage, maintainerNoiseModeLimitation }
    public let code: Code
    public let message: String
    init(_ message: String) {
        self.message = message
        self.code = message.contains("TNOIMOD=1") ? .maintainerNoiseModeLimitation : .originalModelMessage
    }
}

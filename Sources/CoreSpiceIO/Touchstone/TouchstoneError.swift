/// Strict syntax, representation, resource or output failure; no partial result is returned.
public enum TouchstoneError: Error, Sendable, Equatable {
    case invalidConfiguration(String)
    case invalidData(String)
    case syntax(String, at: TouchstoneSourcePosition)
    case unsupportedFeature(String, at: TouchstoneSourcePosition)
    case missingPortCount(at: TouchstoneSourcePosition)
    case limitExceeded(String, limit: UInt64, requested: UInt64, at: TouchstoneSourcePosition)
    case unrepresentable(String)
    case endedSession
    case io(String)
    case cleanup(primary: String, cleanup: String)
}

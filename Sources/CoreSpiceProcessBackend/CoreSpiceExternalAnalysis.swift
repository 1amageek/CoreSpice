/// Analysis capabilities advertised by an explicit external SPICE backend.
public enum CoreSpiceExternalAnalysis: String, Sendable, Hashable, Codable {
    case operatingPoint = "op"
    case dc
    case ac
    case transient = "tran"
    case noise
}

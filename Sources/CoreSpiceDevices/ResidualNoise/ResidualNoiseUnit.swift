/// Unit of a residual-equation excitation; its density is unit squared per Hz.
public enum ResidualNoiseUnit: String, Sendable, Equatable {
    case ampere = "A"
    case volt = "V"
    case watt = "W"
}

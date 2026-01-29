/// SI units for physical quantities in simulation results.
public enum SIUnit: String, Sendable, Hashable, Codable {

    // Base units
    case volt = "V"
    case ampere = "A"
    case second = "s"
    case hertz = "Hz"
    case ohm = "Ω"
    case farad = "F"
    case henry = "H"
    case watt = "W"
    case siemens = "S"

    // Derived units
    case decibel = "dB"
    case degree = "°"
    case radian = "rad"

    // Dimensionless
    case dimensionless = ""

    /// The plural form of this unit for display.
    public var pluralName: String {
        switch self {
        case .volt: return "volts"
        case .ampere: return "amperes"
        case .second: return "seconds"
        case .hertz: return "hertz"
        case .ohm: return "ohms"
        case .farad: return "farads"
        case .henry: return "henries"
        case .watt: return "watts"
        case .siemens: return "siemens"
        case .decibel: return "decibels"
        case .degree: return "degrees"
        case .radian: return "radians"
        case .dimensionless: return ""
        }
    }

    /// Returns the unit string for RAW file output.
    public var rawFileString: String {
        switch self {
        case .volt: return "V"
        case .ampere: return "A"
        case .second: return "s"
        case .hertz: return "Hz"
        case .ohm: return "Ohms"
        case .farad: return "F"
        case .henry: return "H"
        case .watt: return "W"
        case .siemens: return "S"
        case .decibel: return "dB"
        case .degree: return "degrees"
        case .radian: return "radians"
        case .dimensionless: return ""
        }
    }
}

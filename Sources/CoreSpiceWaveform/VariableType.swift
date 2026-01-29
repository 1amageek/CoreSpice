/// The type of a simulation variable.
///
/// Variable types indicate what physical quantity the variable represents.
public enum VariableType: String, Sendable, Hashable, Codable {

    /// Node voltage.
    case voltage

    /// Branch current.
    case current

    /// Time (sweep variable for transient).
    case time

    /// Frequency (sweep variable for AC).
    case frequency

    /// Sweep voltage (for DC sweep).
    case sweepVoltage

    /// Sweep current (for DC sweep).
    case sweepCurrent

    /// Power dissipation.
    case power

    /// Phase angle.
    case phase

    /// Magnitude.
    case magnitude

    /// Real part.
    case real

    /// Imaginary part.
    case imaginary

    /// Noise density.
    case noiseDensity

    /// Temperature.
    case temperature

    /// Generic parameter.
    case parameter

    /// The default SI unit for this variable type.
    public var defaultUnit: SIUnit {
        switch self {
        case .voltage, .sweepVoltage:
            return .volt
        case .current, .sweepCurrent:
            return .ampere
        case .time:
            return .second
        case .frequency:
            return .hertz
        case .power:
            return .watt
        case .phase:
            return .degree
        case .magnitude:
            return .dimensionless
        case .real, .imaginary:
            return .dimensionless
        case .noiseDensity:
            return .dimensionless
        case .temperature:
            return .dimensionless
        case .parameter:
            return .dimensionless
        }
    }
}

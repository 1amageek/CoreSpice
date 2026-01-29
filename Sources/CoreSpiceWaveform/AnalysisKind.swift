/// The kind of analysis that produced a waveform.
public enum AnalysisKind: String, Sendable, Hashable, Codable {

    /// DC operating point.
    case operatingPoint = "op"

    /// DC sweep analysis.
    case dc

    /// AC small-signal analysis.
    case ac

    /// Transient (time-domain) analysis.
    case transient = "tran"

    /// Noise analysis.
    case noise

    /// Transfer function analysis.
    case transferFunction = "tf"

    /// Pole-zero analysis.
    case poleZero = "pz"

    /// Sensitivity analysis.
    case sensitivity = "sens"

    /// The RAW file plot type string for this analysis kind.
    public var rawPlotType: String {
        switch self {
        case .operatingPoint: return "Operating Point"
        case .dc: return "DC transfer characteristic"
        case .ac: return "AC Analysis"
        case .transient: return "Transient Analysis"
        case .noise: return "Noise Spectral Density"
        case .transferFunction: return "Transfer Function"
        case .poleZero: return "Pole-Zero Analysis"
        case .sensitivity: return "Sensitivity Analysis"
        }
    }

    /// Whether this analysis produces complex results.
    public var producesComplexData: Bool {
        switch self {
        case .ac, .noise, .poleZero:
            return true
        case .operatingPoint, .dc, .transient, .transferFunction, .sensitivity:
            return false
        }
    }
}

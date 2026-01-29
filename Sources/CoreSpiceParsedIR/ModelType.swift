/// The type of a device model.
///
/// Model types define the mathematical model used to simulate a device.
public enum ModelType: String, Sendable, Hashable, Codable {

    // Diode models
    case diode = "D"

    // BJT models
    case npn = "NPN"
    case pnp = "PNP"

    // MOSFET models
    case nmos = "NMOS"
    case pmos = "PMOS"

    // JFET models
    case njf = "NJF"
    case pjf = "PJF"

    // MESFET models
    case nmf = "NMF"
    case pmf = "PMF"

    // Transmission line
    case ltra = "LTRA"

    // Switch models
    case sw = "SW"
    case csw = "CSW"

    /// The MOSFET model level for NMOS/PMOS types.
    public enum Level: Int, Sendable, Hashable, Codable {
        case level1 = 1
        case level2 = 2
        case level3 = 3
        case bsim3 = 49
        case bsim4 = 54
    }
}

/// A parsed model definition from the netlist.
public struct ParsedModel: Sendable, Hashable {

    /// The model name used to reference this model.
    public let name: String

    /// The type of device this model describes.
    public let type: ModelType

    /// The model level (for MOSFETs, etc.).
    public let level: Int?

    /// The model parameters.
    public let parameters: [String: ParsedParameterValue]

    /// The source location of this model definition.
    public let location: SourceLocation?

    public init(
        name: String,
        type: ModelType,
        level: Int? = nil,
        parameters: [String: ParsedParameterValue] = [:],
        location: SourceLocation? = nil
    ) {
        self.name = name
        self.type = type
        self.level = level
        self.parameters = parameters
        self.location = location
    }
}

extension ParsedModel: CustomStringConvertible {
    public var description: String {
        var result = ".model \(name) \(type.rawValue)"
        if let lvl = level {
            result += " level=\(lvl)"
        }
        if !parameters.isEmpty {
            result += " ("
            result += parameters.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            result += ")"
        }
        return result
    }
}

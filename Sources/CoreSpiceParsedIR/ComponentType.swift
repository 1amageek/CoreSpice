/// The type of a circuit component.
///
/// Component types determine the device behavior and required parameters.
/// The first letter of the SPICE instance name typically indicates the type.
public enum ComponentType: String, Sendable, Hashable, Codable {

    // Passive elements
    case resistor = "R"
    case capacitor = "C"
    case inductor = "L"
    case coupledInductors = "K"

    // Sources
    case voltageSource = "V"
    case currentSource = "I"

    // Controlled sources
    case vcvs = "E"  // Voltage-controlled voltage source
    case vccs = "G"  // Voltage-controlled current source
    case cccs = "F"  // Current-controlled current source
    case ccvs = "H"  // Current-controlled voltage source

    // Semiconductor devices
    case diode = "D"
    case bjt = "Q"
    case jfet = "J"
    case mosfet = "M"
    case mesfet = "Z"

    // Transmission lines
    case transmissionLine = "T"
    case uniformRC = "U"

    // Special
    case subcircuitInstance = "X"
    case behavioral = "B"
    case switch_ = "S"
    case currentSwitch = "W"

    /// Creates a component type from a SPICE prefix character.
    public init?(prefix: Character) {
        let upper = prefix.uppercased()
        self.init(rawValue: upper)
    }

    /// The number of terminal nodes for this component type.
    ///
    /// Returns `nil` for components with variable node counts (like subcircuits).
    public var standardNodeCount: Int? {
        switch self {
        case .resistor, .capacitor, .inductor, .voltageSource, .currentSource:
            return 2
        case .vcvs, .vccs, .cccs, .ccvs, .switch_, .currentSwitch:
            return 4
        case .diode:
            return 2
        case .bjt:
            return 3
        case .jfet:
            return 3
        case .mosfet:
            return 4
        case .mesfet:
            return 3
        case .transmissionLine, .uniformRC:
            return 4
        case .coupledInductors, .behavioral, .subcircuitInstance:
            return nil
        }
    }
}

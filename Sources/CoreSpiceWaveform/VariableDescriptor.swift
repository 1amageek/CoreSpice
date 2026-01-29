/// Describes a variable in a waveform dataset.
///
/// Variable descriptors provide metadata about each signal in the
/// simulation results, including name, unit, and type information.
public struct VariableDescriptor: Sendable, Hashable, Codable {

    /// The variable name (e.g., "V(out)", "I(R1)").
    public let name: String

    /// The physical unit of this variable.
    public let unit: SIUnit

    /// The type of this variable.
    public let type: VariableType

    /// The index in the data array.
    public let index: Int

    public init(
        name: String,
        unit: SIUnit,
        type: VariableType,
        index: Int
    ) {
        self.name = name
        self.unit = unit
        self.type = type
        self.index = index
    }

    /// Creates a voltage variable descriptor.
    public static func voltage(node: String, index: Int) -> VariableDescriptor {
        VariableDescriptor(
            name: "V(\(node))",
            unit: .volt,
            type: .voltage,
            index: index
        )
    }

    /// Creates a current variable descriptor.
    public static func current(device: String, index: Int) -> VariableDescriptor {
        VariableDescriptor(
            name: "I(\(device))",
            unit: .ampere,
            type: .current,
            index: index
        )
    }

    /// Creates a time variable descriptor (for sweep axis).
    public static func time(index: Int = 0) -> VariableDescriptor {
        VariableDescriptor(
            name: "time",
            unit: .second,
            type: .time,
            index: index
        )
    }

    /// Creates a frequency variable descriptor (for sweep axis).
    public static func frequency(index: Int = 0) -> VariableDescriptor {
        VariableDescriptor(
            name: "frequency",
            unit: .hertz,
            type: .frequency,
            index: index
        )
    }
}

extension VariableDescriptor: CustomStringConvertible {
    public var description: String {
        "\(name) [\(unit.rawValue)]"
    }
}

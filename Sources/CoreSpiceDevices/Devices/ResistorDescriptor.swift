import CoreSpiceIR

/// Descriptor for a two-terminal linear resistor.
public struct ResistorDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "resistor"
    public let portNames = ["pos", "neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "r", defaultValue: nil, description: "Resistance in ohms"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 2 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 2, got: instance.nodes.count
            )
        }

        let resistance: Double
        if let param = instance.parameters["r"] {
            guard case .real(let r) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "r", expected: "real"
                )
            }
            guard r > 0 else {
                throw DeviceBindingError.invalidParameterValue(
                    device: instance.name, parameter: "r", message: "Resistance must be positive"
                )
            }
            resistance = r
        } else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: "r")
        }

        return BoundResistor(
            instance: instance,
            posNode: instance.nodes[0],
            negNode: instance.nodes[1],
            resistance: resistance
        )
    }
}

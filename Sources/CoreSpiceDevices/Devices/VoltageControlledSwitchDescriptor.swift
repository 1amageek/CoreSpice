import CoreSpiceIR

/// Descriptor for a voltage-controlled switch.
public struct VoltageControlledSwitchDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "vswitch"
    public let portNames = ["pos", "neg", "control_pos", "control_neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "ron", defaultValue: .real(1.0), description: "On resistance in ohms"),
        ParameterDescriptor(name: "roff", defaultValue: .real(1.0e12), description: "Off resistance in ohms"),
        ParameterDescriptor(name: "vt", defaultValue: .real(0.0), description: "Switch threshold voltage"),
        ParameterDescriptor(name: "vh", defaultValue: .real(0.0), description: "Switch transition voltage"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 4 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name,
                expected: 4,
                got: instance.nodes.count
            )
        }

        let ron = try realParameter(instance: instance, name: "ron", defaultValue: 1.0)
        let roff = try realParameter(instance: instance, name: "roff", defaultValue: 1.0e12)
        let threshold = try realParameter(instance: instance, name: "vt", defaultValue: 0.0)
        let hysteresis = try realParameter(instance: instance, name: "vh", defaultValue: 0.0)

        guard ron > 0 else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: "ron",
                message: "On resistance must be positive"
            )
        }
        guard roff > ron else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: "roff",
                message: "Off resistance must be greater than on resistance"
            )
        }
        guard threshold.isFinite, hysteresis.isFinite else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: "vt/vh",
                message: "Switch threshold parameters must be finite"
            )
        }

        return BoundVoltageControlledSwitch(
            instance: instance,
            posNode: instance.nodes[0],
            negNode: instance.nodes[1],
            controlPosNode: instance.nodes[2],
            controlNegNode: instance.nodes[3],
            onResistance: ron,
            offResistance: roff,
            threshold: threshold,
            hysteresis: hysteresis
        )
    }

    private func realParameter(
        instance: Instance,
        name: String,
        defaultValue: Double
    ) throws -> Double {
        guard let value = instance.parameters[name] else {
            return defaultValue
        }
        guard case .real(let number) = value else {
            throw DeviceBindingError.invalidParameterType(
                device: instance.name,
                parameter: name,
                expected: "real"
            )
        }
        return number
    }
}

import CoreSpiceIR

/// Descriptor for a current-controlled switch.
public struct CurrentControlledSwitchDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "cswitch"
    public let portNames = ["pos", "neg", "sense_pos", "sense_neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "ron", defaultValue: .real(1.0), description: "On resistance in ohms"),
        ParameterDescriptor(name: "roff", defaultValue: .real(1.0e12), description: "Off resistance in ohms"),
        ParameterDescriptor(name: "it", defaultValue: .real(0.0), description: "Switch threshold current"),
        ParameterDescriptor(name: "ih", defaultValue: .real(0.0), description: "Switch transition current"),
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
        let thresholdCurrent = try realParameter(instance: instance, name: "it", defaultValue: 0.0)
        let hysteresisCurrent = try realParameter(instance: instance, name: "ih", defaultValue: 0.0)

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
        guard thresholdCurrent.isFinite, hysteresisCurrent.isFinite else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: "it/ih",
                message: "Switch threshold parameters must be finite"
            )
        }
        guard hysteresisCurrent == 0 else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: "ih",
                message: "Current-controlled switch hysteresis requires state memory and is not supported by this stateless model"
            )
        }

        let senseBranch = context.allocateBranch()
        guard context.branchIndex(senseBranch) != nil else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: "sense_branch",
                message: "No matrix branch index found for current-controlled switch sense branch"
            )
        }

        return BoundCurrentControlledSwitch(
            instance: instance,
            posNode: instance.nodes[0],
            negNode: instance.nodes[1],
            sensePosNode: instance.nodes[2],
            senseNegNode: instance.nodes[3],
            onResistance: ron,
            offResistance: roff,
            thresholdCurrent: thresholdCurrent,
            hysteresisCurrent: hysteresisCurrent,
            senseBranch: senseBranch
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

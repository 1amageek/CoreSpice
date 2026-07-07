import CoreSpiceIR

/// Descriptor for a current-controlled switch that references an existing source branch.
public struct BranchReferencedCurrentControlledSwitchDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "cswitch_ref"
    public let portNames = ["pos", "neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "ron", defaultValue: .real(1.0), description: "On resistance in ohms"),
        ParameterDescriptor(name: "roff", defaultValue: .real(1.0e12), description: "Off resistance in ohms"),
        ParameterDescriptor(name: "it", defaultValue: .real(0.0), description: "Switch threshold current"),
        ParameterDescriptor(name: "ih", defaultValue: .real(0.0), description: "Switch transition current"),
        ParameterDescriptor(name: "control_source", defaultValue: nil, description: "Controlling voltage source name"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 2 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name,
                expected: 2,
                got: instance.nodes.count
            )
        }

        let ron = try realParameter(instance: instance, name: "ron", defaultValue: 1.0)
        let roff = try realParameter(instance: instance, name: "roff", defaultValue: 1.0e12)
        let thresholdCurrent = try realParameter(instance: instance, name: "it", defaultValue: 0.0)
        let hysteresisCurrent = try realParameter(instance: instance, name: "ih", defaultValue: 0.0)
        let sourceName = try stringParameter(instance: instance, name: "control_source")
        guard let controlBranch = context.branch(named: sourceName) else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: "control_source",
                message: "No branch found for controlling source '\(sourceName)'"
            )
        }
        guard context.branchIndex(controlBranch) != nil else {
            throw DeviceBindingError.invalidParameterValue(
                device: instance.name,
                parameter: "control_source",
                message: "No matrix branch index found for controlling source '\(sourceName)'"
            )
        }

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

        return BoundBranchReferencedCurrentControlledSwitch(
            instance: instance,
            posNode: instance.nodes[0],
            negNode: instance.nodes[1],
            onResistance: ron,
            offResistance: roff,
            thresholdCurrent: thresholdCurrent,
            hysteresisCurrent: hysteresisCurrent,
            controlBranch: controlBranch
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

    private func stringParameter(instance: Instance, name: String) throws -> String {
        guard let value = instance.parameters[name] else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: name)
        }
        guard case .string(let text) = value else {
            throw DeviceBindingError.invalidParameterType(
                device: instance.name,
                parameter: name,
                expected: "string"
            )
        }
        return text
    }
}

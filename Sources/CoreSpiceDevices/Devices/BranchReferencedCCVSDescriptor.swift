import CoreSpiceIR

/// Descriptor for a current-controlled voltage source that references an existing source branch.
public struct BranchReferencedCCVSDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "ccvs_ref"
    public let portNames = ["pos_out", "neg_out"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "h", defaultValue: nil, description: "Transresistance in ohms"),
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

        let transresistance = try realParameter(instance: instance, name: "h")
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

        let outputBranch = context.allocateBranch()

        return BoundBranchReferencedCCVS(
            instance: instance,
            posOut: instance.nodes[0],
            negOut: instance.nodes[1],
            transresistance: transresistance,
            controlBranch: controlBranch,
            outputBranch: outputBranch
        )
    }

    private func realParameter(instance: Instance, name: String) throws -> Double {
        guard let value = instance.parameters[name] else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: name)
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

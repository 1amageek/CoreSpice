import CoreSpiceIR

/// Descriptor for a voltage-output behavioral source.
public struct BehavioralVoltageSourceDescriptor: DeviceDescriptor, Sendable {
    public let typeName = "behavioral_vsource"
    public let portNames = ["pos", "neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(
            name: "v",
            defaultValue: nil,
            description: "Canonical simulation-time voltage expression"
        ),
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
        guard let parameter = instance.parameters["v"] else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: "v")
        }
        guard case .behavioralExpression(let expression) = parameter else {
            throw DeviceBindingError.invalidParameterType(
                device: instance.name,
                parameter: "v",
                expected: "behavioral expression"
            )
        }

        let branch = try context.claimBranch(for: instance)
        guard let branchIndex = context.branchIndex(branch) else {
            throw DeviceBindingError.missingBranchVariable(device: instance.name, ownedIndex: 0)
        }
        return BoundBehavioralVoltageSource(
            instance: instance,
            positiveNodeIndex: context.nodeIndex(instance.nodes[0]),
            negativeNodeIndex: context.nodeIndex(instance.nodes[1]),
            branchIndex: branchIndex,
            evaluator: try BehavioralExpressionEvaluator(
                expression: expression,
                instance: instance,
                context: context
            )
        )
    }
}

import CoreSpiceIR

/// Descriptor for a current-output behavioral source.
public struct BehavioralCurrentSourceDescriptor: DeviceDescriptor, Sendable {
    public let typeName = "behavioral_isource"
    public let portNames = ["pos", "neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(
            name: "i",
            defaultValue: nil,
            description: "Canonical simulation-time current expression"
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
        guard let parameter = instance.parameters["i"] else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: "i")
        }
        guard case .behavioralExpression(let expression) = parameter else {
            throw DeviceBindingError.invalidParameterType(
                device: instance.name,
                parameter: "i",
                expected: "behavioral expression"
            )
        }

        return BoundBehavioralCurrentSource(
            instance: instance,
            positiveNodeIndex: context.nodeIndex(instance.nodes[0]),
            negativeNodeIndex: context.nodeIndex(instance.nodes[1]),
            evaluator: try BehavioralExpressionEvaluator(
                expression: expression,
                instance: instance,
                context: context
            )
        )
    }
}

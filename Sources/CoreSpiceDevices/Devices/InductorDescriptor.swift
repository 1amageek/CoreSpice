import CoreSpiceIR

/// Descriptor for a two-terminal linear inductor.
///
/// The inductor introduces a branch current variable into the MNA
/// system, similar to a voltage source.
public struct InductorDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "inductor"
    public let portNames = ["pos", "neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "l", defaultValue: nil, description: "Inductance in henrys"),
        ParameterDescriptor(name: "ic", defaultValue: .real(0.0), description: "Initial current through inductor"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 2 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 2, got: instance.nodes.count
            )
        }

        let inductance: Double
        if let param = instance.parameters["l"] {
            guard case .real(let l) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "l", expected: "real"
                )
            }
            guard l > 0 else {
                throw DeviceBindingError.invalidParameterValue(
                    device: instance.name, parameter: "l", message: "Inductance must be positive"
                )
            }
            inductance = l
        } else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: "l")
        }

        let initialCurrent: Double
        if let icParam = instance.parameters["ic"], case .real(let ic) = icParam {
            initialCurrent = ic
        } else {
            initialCurrent = 0.0
        }

        let branch = context.allocateBranch()

        return BoundInductor(
            instance: instance,
            posNode: instance.nodes[0],
            negNode: instance.nodes[1],
            inductance: inductance,
            initialCurrent: initialCurrent,
            branch: branch
        )
    }
}

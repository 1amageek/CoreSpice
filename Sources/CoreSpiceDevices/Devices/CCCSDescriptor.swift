import CoreSpiceIR

/// Descriptor for a current-controlled current source (CCCS, F-element).
///
/// Four ports: positive output, negative output, positive sense, negative sense.
/// One sensing branch (zero-volt source across sense terminals).
/// Parameter `f` is the current gain: `I_out = f * I_sense`.
public struct CCCSDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "cccs"
    public let portNames = ["pos_out", "neg_out", "pos_sense", "neg_sense"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "f", defaultValue: nil, description: "Current gain"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 4 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 4, got: instance.nodes.count
            )
        }

        let gain: Double
        if let param = instance.parameters["f"] {
            guard case .real(let f) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "f", expected: "real"
                )
            }
            gain = f
        } else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: "f")
        }

        let senseBranch = context.allocateBranch()

        return BoundCCCS(
            instance: instance,
            posOut: instance.nodes[0],
            negOut: instance.nodes[1],
            posSense: instance.nodes[2],
            negSense: instance.nodes[3],
            gain: gain,
            senseBranch: senseBranch
        )
    }
}

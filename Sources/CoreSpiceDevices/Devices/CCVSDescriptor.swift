import CoreSpiceIR

/// Descriptor for a current-controlled voltage source (CCVS, H-element).
///
/// Four ports: positive output, negative output, positive sense, negative sense.
/// Two branches: sensing branch (measures controlling current) and output branch.
/// Parameter `h` is the transresistance: `V_out = h * I_sense`.
public struct CCVSDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "ccvs"
    public let portNames = ["pos_out", "neg_out", "pos_sense", "neg_sense"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "h", defaultValue: nil, description: "Transresistance in ohms"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 4 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 4, got: instance.nodes.count
            )
        }

        let transresistance: Double
        if let param = instance.parameters["h"] {
            guard case .real(let h) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "h", expected: "real"
                )
            }
            transresistance = h
        } else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: "h")
        }

        let senseBranch = context.allocateBranch()
        let outputBranch = context.allocateBranch()

        return BoundCCVS(
            instance: instance,
            posOut: instance.nodes[0],
            negOut: instance.nodes[1],
            posSense: instance.nodes[2],
            negSense: instance.nodes[3],
            transresistance: transresistance,
            senseBranch: senseBranch,
            outputBranch: outputBranch
        )
    }
}

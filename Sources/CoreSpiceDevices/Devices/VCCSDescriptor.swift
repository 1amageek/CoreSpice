import CoreSpiceIR

/// Descriptor for a voltage-controlled current source (VCCS, G-element).
///
/// Four ports: positive output, negative output, positive control, negative control.
/// Parameter `g` is the transconductance: `I_out = g * (V_ctrl+ - V_ctrl-)`.
public struct VCCSDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "vccs"
    public let portNames = ["pos_out", "neg_out", "pos_ctrl", "neg_ctrl"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "g", defaultValue: nil, description: "Transconductance in siemens"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 4 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 4, got: instance.nodes.count
            )
        }

        let transconductance: Double
        if let param = instance.parameters["g"] {
            guard case .real(let g) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "g", expected: "real"
                )
            }
            transconductance = g
        } else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: "g")
        }

        return BoundVCCS(
            instance: instance,
            posOut: instance.nodes[0],
            negOut: instance.nodes[1],
            posCtrl: instance.nodes[2],
            negCtrl: instance.nodes[3],
            transconductance: transconductance
        )
    }
}

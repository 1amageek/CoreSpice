import CoreSpiceIR

/// Descriptor for a voltage-controlled voltage source (VCVS, E-element).
///
/// Four ports: positive output, negative output, positive control, negative control.
/// Parameter `e` is the voltage gain: `V_out = e * (V_ctrl+ - V_ctrl-)`.
public struct VCVSDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "vcvs"
    public let portNames = ["pos_out", "neg_out", "pos_ctrl", "neg_ctrl"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "e", defaultValue: nil, description: "Voltage gain"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 4 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 4, got: instance.nodes.count
            )
        }

        let gain: Double
        if let param = instance.parameters["e"] {
            guard case .real(let e) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "e", expected: "real"
                )
            }
            gain = e
        } else {
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: "e")
        }

        let branch = context.allocateBranch()

        return BoundVCVS(
            instance: instance,
            posOut: instance.nodes[0],
            negOut: instance.nodes[1],
            posCtrl: instance.nodes[2],
            negCtrl: instance.nodes[3],
            gain: gain,
            branch: branch
        )
    }
}

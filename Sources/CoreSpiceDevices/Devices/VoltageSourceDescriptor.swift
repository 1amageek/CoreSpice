import CoreSpiceIR

/// Descriptor for an independent voltage source.
///
/// Supports DC voltage and time-varying waveforms for transient analysis.
public struct VoltageSourceDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "vsource"
    public let portNames = ["pos", "neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "v", defaultValue: .real(0.0), description: "DC voltage in volts"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 2 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 2, got: instance.nodes.count
            )
        }

        let dcVoltage: Double
        if let param = instance.parameters["v"] {
            guard case .real(let v) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "v", expected: "real"
                )
            }
            dcVoltage = v
        } else {
            dcVoltage = 0.0
        }

        let branch = context.allocateBranch()

        return BoundVoltageSource(
            instance: instance,
            posNode: instance.nodes[0],
            negNode: instance.nodes[1],
            dcVoltage: dcVoltage,
            waveform: .dc(dcVoltage),
            branch: branch
        )
    }
}

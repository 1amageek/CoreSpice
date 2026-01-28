import CoreSpiceIR

/// Descriptor for an independent current source.
///
/// Supports DC current and time-varying waveforms for transient analysis.
public struct CurrentSourceDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "isource"
    public let portNames = ["pos", "neg"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "i", defaultValue: .real(0.0), description: "DC current in amperes"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 2 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 2, got: instance.nodes.count
            )
        }

        let dcCurrent: Double
        if let param = instance.parameters["i"] {
            guard case .real(let i) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "i", expected: "real"
                )
            }
            dcCurrent = i
        } else {
            dcCurrent = 0.0
        }

        return BoundCurrentSource(
            instance: instance,
            posNode: instance.nodes[0],
            negNode: instance.nodes[1],
            dcCurrent: dcCurrent,
            waveform: .dc(dcCurrent)
        )
    }
}

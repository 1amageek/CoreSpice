import CoreSpiceIR
import CoreSpiceDevices

/// Descriptor for a single 2x2 Mach-Zehnder Interferometer device.
///
/// This device has four ports (in0, in1, out0, out1) and is
/// parameterised by internal phase `theta`, external phase `phi`,
/// and insertion loss `loss`. It can participate in SPICE-level
/// mixed-signal simulations alongside electronic components.
public struct MZI2x2Descriptor: DeviceDescriptor, Sendable {

    public let typeName = "mzi2x2"

    public let portNames = ["in0", "in1", "out0", "out1"]

    public let parameterDescriptors: [ParameterDescriptor] = [
        ParameterDescriptor(name: "theta", defaultValue: .real(0), description: "Phase shift"),
        ParameterDescriptor(name: "phi", defaultValue: .real(0), description: "External phase"),
        ParameterDescriptor(name: "loss", defaultValue: .real(1.0), description: "Insertion loss"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 4 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 4, got: instance.nodes.count
            )
        }

        let theta: Double
        if let param = instance.parameters["theta"] {
            guard case .real(let v) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "theta", expected: "real"
                )
            }
            theta = v
        } else {
            theta = 0
        }

        let phi: Double
        if let param = instance.parameters["phi"] {
            guard case .real(let v) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "phi", expected: "real"
                )
            }
            phi = v
        } else {
            phi = 0
        }

        let loss: Double
        if let param = instance.parameters["loss"] {
            guard case .real(let v) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "loss", expected: "real"
                )
            }
            loss = v
        } else {
            loss = 1.0
        }

        return BoundMZI2x2(instance: instance, theta: theta, phi: phi, loss: loss)
    }
}

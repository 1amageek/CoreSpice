import CoreSpiceIR
import CoreSpiceDevices

/// Descriptor for a simple photonic waveguide device.
///
/// The waveguide is a two-port element parameterised by physical
/// length, effective refractive index, and propagation loss. It
/// introduces a wavelength-dependent phase shift and attenuation
/// to the optical signal passing through it.
public struct WaveguideDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "waveguide"

    public let portNames = ["in", "out"]

    public let parameterDescriptors: [ParameterDescriptor] = [
        ParameterDescriptor(name: "length", defaultValue: .real(1e-3), description: "Waveguide length (m)"),
        ParameterDescriptor(name: "neff", defaultValue: .real(2.4), description: "Effective index"),
        ParameterDescriptor(name: "loss_db_per_cm", defaultValue: .real(2.0), description: "Propagation loss"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 2 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 2, got: instance.nodes.count
            )
        }

        let length: Double
        if let param = instance.parameters["length"] {
            guard case .real(let v) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "length", expected: "real"
                )
            }
            length = v
        } else {
            length = 1e-3
        }

        let neff: Double
        if let param = instance.parameters["neff"] {
            guard case .real(let v) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "neff", expected: "real"
                )
            }
            neff = v
        } else {
            neff = 2.4
        }

        let lossDB: Double
        if let param = instance.parameters["loss_db_per_cm"] {
            guard case .real(let v) = param else {
                throw DeviceBindingError.invalidParameterType(
                    device: instance.name, parameter: "loss_db_per_cm", expected: "real"
                )
            }
            lossDB = v
        } else {
            lossDB = 2.0
        }

        return BoundWaveguide(
            instance: instance,
            length: length,
            neff: neff,
            lossDBPerCm: lossDB
        )
    }
}

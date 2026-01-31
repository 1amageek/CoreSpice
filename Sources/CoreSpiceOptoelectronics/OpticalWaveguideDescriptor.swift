import CoreSpiceIR
import CoreSpiceDevices

/// Device descriptor for an optical waveguide.
///
/// Purely optical device: no electrical ports.
/// Optical ports: optical_in, optical_out.
///
/// Propagation: attenuation + phase shift.
/// Group delay is not modeled (instantaneous propagation).
public struct OpticalWaveguideDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "waveguide"
    public let portNames: [String] = []

    public let parameterDescriptors: [ParameterDescriptor] = [
        ParameterDescriptor(name: "length", defaultValue: .real(1e-2), description: "Waveguide length (m)"),
        ParameterDescriptor(name: "neff", defaultValue: .real(1.45), description: "Effective refractive index"),
        ParameterDescriptor(name: "ng", defaultValue: .real(1.5), description: "Group refractive index"),
        ParameterDescriptor(name: "loss", defaultValue: .real(0.5), description: "Propagation loss (dB/cm)"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        let length = extractReal(instance.parameters["length"]) ?? 1e-2
        let neff = extractReal(instance.parameters["neff"]) ?? 1.45
        let ng = extractReal(instance.parameters["ng"]) ?? 1.5
        let loss = extractReal(instance.parameters["loss"]) ?? 0.5

        // Optical nodes: first = input, second = output
        let opticalInput: OpticalNode
        let opticalOutput: OpticalNode
        if instance.opticalNodes.count >= 2 {
            opticalInput = instance.opticalNodes[0]
            opticalOutput = instance.opticalNodes[1]
        } else {
            opticalInput = OpticalNode(id: 0)
            opticalOutput = OpticalNode(id: 1)
        }

        return BoundOpticalWaveguide(
            instance: instance,
            inputNode: opticalInput,
            outputNode: opticalOutput,
            length: length,
            neff: neff,
            ng: ng,
            lossdBperCm: loss
        )
    }

    private func extractReal(_ value: ParameterValue?) -> Double? {
        guard let value else { return nil }
        if case .real(let v) = value { return v }
        return nil
    }
}

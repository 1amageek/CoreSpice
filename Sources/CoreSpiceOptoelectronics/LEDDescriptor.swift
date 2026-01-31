import CoreSpiceIR
import CoreSpiceDevices

/// Device descriptor for a light-emitting diode (LED).
///
/// Ports: anode, cathode (electrical) + optical_out (optical output).
/// The LED emits light proportional to forward current with external
/// quantum efficiency: `P = eta_ext * I_fwd * h*nu/q`.
public struct LEDDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "led"
    public let portNames = ["anode", "cathode"]

    public let parameterDescriptors: [ParameterDescriptor] = [
        ParameterDescriptor(name: "is", defaultValue: .real(1e-14), description: "Saturation current (A)"),
        ParameterDescriptor(name: "n", defaultValue: .real(2.0), description: "Emission coefficient"),
        ParameterDescriptor(name: "rs", defaultValue: .real(5.0), description: "Series resistance (ohm)"),
        ParameterDescriptor(name: "cjo", defaultValue: .real(10e-12), description: "Zero-bias junction capacitance (F)"),
        ParameterDescriptor(name: "vj", defaultValue: .real(0.7), description: "Junction potential (V)"),
        ParameterDescriptor(name: "m", defaultValue: .real(0.5), description: "Grading coefficient"),
        ParameterDescriptor(name: "eta_ext", defaultValue: .real(0.1), description: "External quantum efficiency"),
        ParameterDescriptor(name: "lambda", defaultValue: .real(850e-9), description: "Peak wavelength (m)"),
        ParameterDescriptor(name: "tau_rad", defaultValue: .real(10e-9), description: "Radiative lifetime (s)"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count >= 2 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 2, got: instance.nodes.count
            )
        }

        let params = LEDModelParameters(
            saturationCurrent: extractReal(instance.parameters["is"]) ?? 1e-14,
            emissionCoefficient: extractReal(instance.parameters["n"]) ?? 2.0,
            seriesResistance: extractReal(instance.parameters["rs"]) ?? 5.0,
            junctionCapacitance: extractReal(instance.parameters["cjo"]) ?? 10e-12,
            junctionPotential: extractReal(instance.parameters["vj"]) ?? 0.7,
            gradingCoefficient: extractReal(instance.parameters["m"]) ?? 0.5,
            externalQuantumEfficiency: extractReal(instance.parameters["eta_ext"]) ?? 0.1,
            peakWavelength: extractReal(instance.parameters["lambda"]) ?? 850e-9,
            radiativeLifetime: extractReal(instance.parameters["tau_rad"]) ?? 10e-9
        )

        let anodeNode = instance.nodes[0]
        let cathodeNode = instance.nodes[1]
        let opticalOutput = instance.opticalNodes.first ?? OpticalNode(id: 0)

        return BoundLED(
            instance: instance,
            anode: anodeNode,
            cathode: cathodeNode,
            anodeIdx: context.nodeIndex(anodeNode),
            cathodeIdx: context.nodeIndex(cathodeNode),
            opticalOutput: opticalOutput,
            parameters: params
        )
    }

    private func extractReal(_ value: ParameterValue?) -> Double? {
        guard let value else { return nil }
        if case .real(let v) = value { return v }
        return nil
    }
}

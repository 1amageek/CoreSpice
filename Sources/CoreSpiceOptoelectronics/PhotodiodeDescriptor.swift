import CoreSpiceIR
import CoreSpiceDevices

/// Device descriptor for a photodiode.
///
/// Ports: anode, cathode (electrical) + optical_in (optical input).
/// The optical input receives light from the optical network; the
/// generated photocurrent is injected between anode and cathode.
public struct PhotodiodeDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "photodiode"
    public let portNames = ["anode", "cathode"]

    public let parameterDescriptors: [ParameterDescriptor] = [
        ParameterDescriptor(name: "is", defaultValue: .real(1e-14), description: "Saturation current (A)"),
        ParameterDescriptor(name: "n", defaultValue: .real(1.0), description: "Emission coefficient"),
        ParameterDescriptor(name: "rs", defaultValue: .real(0.0), description: "Series resistance (ohm)"),
        ParameterDescriptor(name: "bv", defaultValue: .real(1e100), description: "Breakdown voltage (V)"),
        ParameterDescriptor(name: "ibv", defaultValue: .real(1e-3), description: "Current at breakdown (A)"),
        ParameterDescriptor(name: "cjo", defaultValue: .real(0.5e-12), description: "Zero-bias junction capacitance (F)"),
        ParameterDescriptor(name: "vj", defaultValue: .real(0.7), description: "Junction potential (V)"),
        ParameterDescriptor(name: "m", defaultValue: .real(0.5), description: "Grading coefficient"),
        ParameterDescriptor(name: "tt", defaultValue: .real(0.0), description: "Transit time (s)"),
        ParameterDescriptor(name: "resp", defaultValue: .real(0.8), description: "Responsivity (A/W)"),
        ParameterDescriptor(name: "lamref", defaultValue: .real(1550e-9), description: "Reference wavelength (m)"),
        ParameterDescriptor(name: "idark", defaultValue: .real(1e-9), description: "Dark current (A)"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count >= 2 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 2, got: instance.nodes.count
            )
        }

        let params = PhotodiodeModelParameters(
            saturationCurrent: extractReal(instance.parameters["is"]) ?? 1e-14,
            emissionCoefficient: extractReal(instance.parameters["n"]) ?? 1.0,
            seriesResistance: extractReal(instance.parameters["rs"]) ?? 0.0,
            breakdownVoltage: extractReal(instance.parameters["bv"]) ?? .infinity,
            breakdownCurrent: extractReal(instance.parameters["ibv"]) ?? 1e-3,
            junctionCapacitance: extractReal(instance.parameters["cjo"]) ?? 0.5e-12,
            junctionPotential: extractReal(instance.parameters["vj"]) ?? 0.7,
            gradingCoefficient: extractReal(instance.parameters["m"]) ?? 0.5,
            transitTime: extractReal(instance.parameters["tt"]) ?? 0.0,
            responsivity: extractReal(instance.parameters["resp"]) ?? 0.8,
            referenceWavelength: extractReal(instance.parameters["lamref"]) ?? 1550e-9,
            darkCurrent: extractReal(instance.parameters["idark"]) ?? 1e-9
        )

        let anodeNode = instance.nodes[0]
        let cathodeNode = instance.nodes[1]

        // Optical input node (from instance.opticalNodes)
        let opticalInput = instance.opticalNodes.first ?? OpticalNode(id: 0)

        return BoundPhotodiode(
            instance: instance,
            anode: anodeNode,
            cathode: cathodeNode,
            anodeIdx: context.nodeIndex(anodeNode),
            cathodeIdx: context.nodeIndex(cathodeNode),
            opticalInput: opticalInput,
            parameters: params
        )
    }

    private func extractReal(_ value: ParameterValue?) -> Double? {
        guard let value else { return nil }
        if case .real(let v) = value { return v }
        return nil
    }
}

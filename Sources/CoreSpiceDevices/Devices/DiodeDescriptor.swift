import CoreSpiceIR

/// Descriptor for a PN junction diode.
///
/// The diode has two terminals: anode (positive) and cathode (negative).
/// Current flows from anode to cathode when forward biased.
public struct DiodeDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "diode"
    public let portNames = ["anode", "cathode"]

    public let parameterDescriptors: [ParameterDescriptor] = [
        ParameterDescriptor(name: "is", defaultValue: .real(1e-14), description: "Saturation current (A)"),
        ParameterDescriptor(name: "n", defaultValue: .real(1.0), description: "Emission coefficient"),
        ParameterDescriptor(name: "rs", defaultValue: .real(0.0), description: "Series resistance (Ω)"),
        ParameterDescriptor(name: "bv", defaultValue: .real(1e100), description: "Breakdown voltage (V)"),
        ParameterDescriptor(name: "ibv", defaultValue: .real(1e-3), description: "Current at breakdown (A)"),
        ParameterDescriptor(name: "cjo", defaultValue: .real(0.0), description: "Zero-bias junction capacitance (F)"),
        ParameterDescriptor(name: "vj", defaultValue: .real(1.0), description: "Junction potential (V)"),
        ParameterDescriptor(name: "m", defaultValue: .real(0.5), description: "Grading coefficient"),
        ParameterDescriptor(name: "tt", defaultValue: .real(0.0), description: "Transit time (s)"),
        ParameterDescriptor(name: "eg", defaultValue: .real(1.11), description: "Energy gap (eV)"),
        ParameterDescriptor(name: "xti", defaultValue: .real(3.0), description: "Saturation current temperature exponent"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count == 2 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name,
                expected: 2,
                got: instance.nodes.count
            )
        }

        let params = DiodeModelParameters(
            saturationCurrent: extractReal(instance.parameters["is"]) ?? 1e-14,
            emissionCoefficient: extractReal(instance.parameters["n"]) ?? 1.0,
            seriesResistance: extractReal(instance.parameters["rs"]) ?? 0.0,
            breakdownVoltage: extractReal(instance.parameters["bv"]) ?? 1e100,
            breakdownCurrent: extractReal(instance.parameters["ibv"]) ?? 1e-3,
            junctionCapacitance: extractReal(instance.parameters["cjo"]) ?? 0.0,
            junctionPotential: extractReal(instance.parameters["vj"]) ?? 1.0,
            gradingCoefficient: extractReal(instance.parameters["m"]) ?? 0.5,
            transitTime: extractReal(instance.parameters["tt"]) ?? 0.0,
            energyGap: extractReal(instance.parameters["eg"]) ?? 1.11,
            saturationCurrentExponent: extractReal(instance.parameters["xti"]) ?? 3.0
        )

        return BoundDiode(
            instance: instance,
            anode: instance.nodes[0],
            cathode: instance.nodes[1],
            parameters: params
        )
    }

    private func extractReal(_ value: ParameterValue?) -> Double? {
        guard case .real(let v) = value else { return nil }
        return v
    }
}

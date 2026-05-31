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
            saturationCurrent: try extractReal(instance.parameters["is"], parameter: "is", device: instance.name) ?? 1e-14,
            emissionCoefficient: try extractReal(instance.parameters["n"], parameter: "n", device: instance.name) ?? 1.0,
            seriesResistance: try extractReal(instance.parameters["rs"], parameter: "rs", device: instance.name) ?? 0.0,
            breakdownVoltage: try extractReal(instance.parameters["bv"], parameter: "bv", device: instance.name) ?? 1e100,
            breakdownCurrent: try extractReal(instance.parameters["ibv"], parameter: "ibv", device: instance.name) ?? 1e-3,
            junctionCapacitance: try extractReal(instance.parameters["cjo"], parameter: "cjo", device: instance.name) ?? 0.0,
            junctionPotential: try extractReal(instance.parameters["vj"], parameter: "vj", device: instance.name) ?? 1.0,
            gradingCoefficient: try extractReal(instance.parameters["m"], parameter: "m", device: instance.name) ?? 0.5,
            transitTime: try extractReal(instance.parameters["tt"], parameter: "tt", device: instance.name) ?? 0.0,
            energyGap: try extractReal(instance.parameters["eg"], parameter: "eg", device: instance.name) ?? 1.11,
            saturationCurrentExponent: try extractReal(instance.parameters["xti"], parameter: "xti", device: instance.name) ?? 3.0
        )
        try params.validate(device: instance.name)

        let anodeNode = instance.nodes[0]
        let cathodeNode = instance.nodes[1]
        let anodeIdx = context.nodeIndex(anodeNode)
        let cathodeIdx = context.nodeIndex(cathodeNode)

        // Pre-resolve CSR value indices for O(1) stamping
        let stampAA = anodeIdx.flatMap { i in context.stampIndex(row: i, col: i) }
        let stampCC = cathodeIdx.flatMap { i in context.stampIndex(row: i, col: i) }
        let stampAC: Int? = if let i = anodeIdx, let j = cathodeIdx { context.stampIndex(row: i, col: j) } else { nil }
        let stampCA: Int? = if let i = cathodeIdx, let j = anodeIdx { context.stampIndex(row: i, col: j) } else { nil }

        return BoundDiode(
            instance: instance,
            anode: anodeNode,
            cathode: cathodeNode,
            anodeIdx: anodeIdx,
            cathodeIdx: cathodeIdx,
            parameters: params,
            stampAA: stampAA,
            stampCC: stampCC,
            stampAC: stampAC,
            stampCA: stampCA
        )
    }

    private func extractReal(_ value: ParameterValue?, parameter: String, device: String) throws -> Double? {
        guard let value else { return nil }
        guard case .real(let v) = value else {
            throw DeviceBindingError.invalidParameterType(
                device: device,
                parameter: parameter,
                expected: "real"
            )
        }
        return v
    }
}

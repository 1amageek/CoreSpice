import CoreSpiceIR
import CoreSpiceDevices

/// Device descriptor for a Mach-Zehnder electro-optic modulator (MZM).
///
/// Ports: signal_pos, signal_neg, bias_pos, bias_neg (electrical)
///        + optical_in, optical_out (optical).
///
/// Transfer function: `P_out = P_in * IL * cos²(π*(V_bias+V_sig)/(2*Vπ) + φ₀)`
public struct EOModulatorDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "eomod"
    public let portNames = ["signal_pos", "signal_neg", "bias_pos", "bias_neg"]

    public let parameterDescriptors: [ParameterDescriptor] = [
        ParameterDescriptor(name: "vpi", defaultValue: .real(3.5), description: "Half-wave voltage (V)"),
        ParameterDescriptor(name: "il", defaultValue: .real(0.95), description: "Insertion loss (linear, 0..1)"),
        ParameterDescriptor(name: "er", defaultValue: .real(1e-3), description: "Extinction ratio (linear)"),
        ParameterDescriptor(name: "phi0", defaultValue: .real(0.0), description: "Bias phase offset (rad)"),
        ParameterDescriptor(name: "c_elec", defaultValue: .real(0.5e-12), description: "Electrode capacitance (F)"),
        ParameterDescriptor(name: "r_elec", defaultValue: .real(50.0), description: "Electrode resistance (ohm)"),
        ParameterDescriptor(name: "bw", defaultValue: .real(40e9), description: "Electrical bandwidth (Hz)"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count >= 4 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 4, got: instance.nodes.count
            )
        }

        let params = EOModulatorModelParameters(
            vPi: extractReal(instance.parameters["vpi"]) ?? 3.5,
            insertionLoss: extractReal(instance.parameters["il"]) ?? 0.95,
            extinctionRatioLinear: extractReal(instance.parameters["er"]) ?? 1e-3,
            biasPhase: extractReal(instance.parameters["phi0"]) ?? 0.0,
            electrodeCapacitance: extractReal(instance.parameters["c_elec"]) ?? 0.5e-12,
            electrodeResistance: extractReal(instance.parameters["r_elec"]) ?? 50.0,
            bandwidth: extractReal(instance.parameters["bw"]) ?? 40e9
        )

        let sigPos = instance.nodes[0]
        let sigNeg = instance.nodes[1]
        let biasPos = instance.nodes[2]
        let biasNeg = instance.nodes[3]

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

        return BoundEOModulator(
            instance: instance,
            signalPos: sigPos,
            signalNeg: sigNeg,
            biasPos: biasPos,
            biasNeg: biasNeg,
            signalPosIdx: context.nodeIndex(sigPos),
            signalNegIdx: context.nodeIndex(sigNeg),
            biasPosIdx: context.nodeIndex(biasPos),
            biasNegIdx: context.nodeIndex(biasNeg),
            opticalInput: opticalInput,
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

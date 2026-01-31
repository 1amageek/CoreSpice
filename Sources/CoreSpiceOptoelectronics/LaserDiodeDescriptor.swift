import CoreSpiceIR
import CoreSpiceDevices

/// Device descriptor for a Fabry-Perot or single-mode laser diode.
///
/// Ports: anode, cathode (electrical) + optical_out (optical output).
/// DC: Above threshold `P = slope_eff * (I - I_th)`.
/// AC: Small-signal transfer with relaxation oscillation.
/// Transient: Rate equations for carrier/photon densities.
public struct LaserDiodeDescriptor: DeviceDescriptor, Sendable {

    public let typeName = "laser"
    public let portNames = ["anode", "cathode"]

    public let parameterDescriptors: [ParameterDescriptor] = [
        // PN junction
        ParameterDescriptor(name: "is", defaultValue: .real(1e-14), description: "Saturation current (A)"),
        ParameterDescriptor(name: "n", defaultValue: .real(2.0), description: "Emission coefficient"),
        ParameterDescriptor(name: "rs", defaultValue: .real(5.0), description: "Series resistance (ohm)"),
        ParameterDescriptor(name: "cjo", defaultValue: .real(2e-12), description: "Zero-bias junction capacitance (F)"),
        ParameterDescriptor(name: "vj", defaultValue: .real(0.7), description: "Junction potential (V)"),
        ParameterDescriptor(name: "m", defaultValue: .real(0.5), description: "Grading coefficient"),
        // Laser optical
        ParameterDescriptor(name: "ith", defaultValue: .real(20e-3), description: "Threshold current (A)"),
        ParameterDescriptor(name: "slope_eff", defaultValue: .real(0.3), description: "Slope efficiency (W/A)"),
        ParameterDescriptor(name: "lambda", defaultValue: .real(1550e-9), description: "Lasing wavelength (m)"),
        // Rate equation
        ParameterDescriptor(name: "tau_n", defaultValue: .real(1e-9), description: "Carrier lifetime (s)"),
        ParameterDescriptor(name: "tau_p", defaultValue: .real(2e-12), description: "Photon lifetime (s)"),
        ParameterDescriptor(name: "v_act", defaultValue: .real(3e-17), description: "Active region volume (m^3)"),
        ParameterDescriptor(name: "gamma", defaultValue: .real(0.3), description: "Optical confinement factor"),
        ParameterDescriptor(name: "g0", defaultValue: .real(2.5e-12), description: "Volumetric differential gain v_g*a (m^3/s)"),
        ParameterDescriptor(name: "n_tr", defaultValue: .real(1.5e24), description: "Transparency carrier density (1/m^3)"),
        ParameterDescriptor(name: "beta_sp", defaultValue: .real(1e-4), description: "Spontaneous emission factor"),
        // Noise
        ParameterDescriptor(name: "rin", defaultValue: .real(-155), description: "RIN (dB/Hz)"),
        // Temperature
        ParameterDescriptor(name: "t0", defaultValue: .real(50.0), description: "Characteristic temperature (K)"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        guard instance.nodes.count >= 2 else {
            throw DeviceBindingError.portCountMismatch(
                device: instance.name, expected: 2, got: instance.nodes.count
            )
        }

        let params = LaserDiodeModelParameters(
            saturationCurrent: extractReal(instance.parameters["is"]) ?? 1e-14,
            emissionCoefficient: extractReal(instance.parameters["n"]) ?? 2.0,
            seriesResistance: extractReal(instance.parameters["rs"]) ?? 5.0,
            junctionCapacitance: extractReal(instance.parameters["cjo"]) ?? 2e-12,
            junctionPotential: extractReal(instance.parameters["vj"]) ?? 0.7,
            gradingCoefficient: extractReal(instance.parameters["m"]) ?? 0.5,
            thresholdCurrent: extractReal(instance.parameters["ith"]) ?? 20e-3,
            slopeEfficiency: extractReal(instance.parameters["slope_eff"]) ?? 0.3,
            wavelength: extractReal(instance.parameters["lambda"]) ?? 1550e-9,
            carrierLifetime: extractReal(instance.parameters["tau_n"]) ?? 1e-9,
            photonLifetime: extractReal(instance.parameters["tau_p"]) ?? 2e-12,
            activeVolume: extractReal(instance.parameters["v_act"]) ?? 3e-17,
            confinementFactor: extractReal(instance.parameters["gamma"]) ?? 0.3,
            differentialGain: extractReal(instance.parameters["g0"]) ?? 2.5e-20,
            transparencyCarrierDensity: extractReal(instance.parameters["n_tr"]) ?? 1.5e24,
            spontaneousEmissionFactor: extractReal(instance.parameters["beta_sp"]) ?? 1e-4,
            rinDB: extractReal(instance.parameters["rin"]) ?? -155,
            characteristicTemperature: extractReal(instance.parameters["t0"]) ?? 50.0
        )

        let anodeNode = instance.nodes[0]
        let cathodeNode = instance.nodes[1]
        let opticalOutput = instance.opticalNodes.first ?? OpticalNode(id: 0)

        return BoundLaserDiode(
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

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
        ParameterDescriptor(name: "tnom", defaultValue: .real(27.0), description: "Model nominal temperature (°C)"),
        ParameterDescriptor(name: "tnom_k", defaultValue: .real(300.15), description: "Model nominal temperature (K)"),
    ]

    public init() {}

    public func bind(instance: Instance, context: inout BindingContext) throws -> any BoundDevice {
        throw DeviceBindingError.diodePreparationRequired(device: instance.name)
    }
}

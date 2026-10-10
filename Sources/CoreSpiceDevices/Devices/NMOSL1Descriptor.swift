import CoreSpiceIR
import CoreSpiceMOSContracts

/// Descriptor for an NMOS Level 1 MOSFET (Shichman-Hodges model).
///
/// Four ports: drain, gate, source, bulk. Body effect is modeled
/// via `gamma` and `phi` parameters using the bulk-source voltage.
public struct NMOSL1Descriptor: DeviceDescriptor, Sendable {

    public let typeName = "nmos_l1"
    public let portNames = ["drain", "gate", "source", "bulk"]
    public let parameterDescriptors = [
        ParameterDescriptor(name: "w", defaultValue: .real(10e-6), description: "Channel width (m)"),
        ParameterDescriptor(name: "l", defaultValue: .real(1e-6), description: "Channel length (m)"),
        ParameterDescriptor(name: "vto", defaultValue: .real(0.0), description: "Threshold voltage (V)"),
        ParameterDescriptor(name: "kp", defaultValue: .real(2e-5), description: "Transconductance parameter (A/V^2)"),
        ParameterDescriptor(name: "gamma", defaultValue: .real(0.0), description: "Body effect coefficient (V^0.5)"),
        ParameterDescriptor(name: "phi", defaultValue: .real(0.6), description: "Surface potential (V)"),
        ParameterDescriptor(name: "lambda", defaultValue: .real(0.0), description: "Channel-length modulation (1/V)"),
        ParameterDescriptor(name: "tox", defaultValue: .real(0), description: "Gate oxide thickness (m); 0 = unspecified, no intrinsic gate capacitance (SPICE convention)"),
        ParameterDescriptor(name: "cgso", defaultValue: .real(0), description: "Gate-source overlap capacitance (F/m)"),
        ParameterDescriptor(name: "cgdo", defaultValue: .real(0), description: "Gate-drain overlap capacitance (F/m)"),
        ParameterDescriptor(name: "cgbo", defaultValue: .real(0), description: "Gate-bulk overlap capacitance (F/m)"),
        ParameterDescriptor(name: "cj", defaultValue: .real(0), description: "Bulk junction bottom capacitance (F/m^2)"),
        ParameterDescriptor(name: "cjsw", defaultValue: .real(0), description: "Bulk junction sidewall capacitance (F/m)"),
        ParameterDescriptor(name: "mj", defaultValue: .real(0.5), description: "Junction grading coefficient"),
        ParameterDescriptor(name: "mjsw", defaultValue: .real(0.33), description: "Sidewall grading coefficient"),
        ParameterDescriptor(name: "pb", defaultValue: .real(0.8), description: "Bulk junction potential (V)"),
        ParameterDescriptor(name: "ad", defaultValue: .real(0), description: "Drain diffusion area (m^2)"),
        ParameterDescriptor(name: "as", defaultValue: .real(0), description: "Source diffusion area (m^2)"),
        ParameterDescriptor(name: "pd", defaultValue: .real(0), description: "Drain diffusion perimeter (m)"),
        ParameterDescriptor(name: "ps", defaultValue: .real(0), description: "Source diffusion perimeter (m)"),
    ]

    public init() {}

    /// Raw MOS binding is unsupported; consume a checked NativePreparedMOSDevice instead.
    public func bind(instance: Instance, context: inout BindingContext)
        throws(MOSBindingFailure) -> any BoundDevice {
        throw .missingPreparedReceipt
    }
}

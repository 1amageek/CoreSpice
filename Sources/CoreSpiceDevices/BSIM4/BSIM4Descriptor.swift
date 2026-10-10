import CoreSpiceIR
import CoreSpiceMOSContracts

/// Native Level 54 descriptor for one explicitly selected MOS polarity.
public struct BSIM4Descriptor: DeviceDescriptor {
    public let typeName: String
    public let portNames = ["drain", "gate", "source", "bulk"]
    public let parameterDescriptors: [ParameterDescriptor] = []

    public init(pmos: Bool = false) { typeName = pmos ? "pmos_l54" : "nmos_l54" }

    /// Raw MOS binding is unsupported; consume a checked NativePreparedMOSDevice instead.
    public func bind(instance: Instance, context: inout BindingContext)
        throws(MOSBindingFailure) -> any BoundDevice {
        throw .missingPreparedReceipt
    }
}

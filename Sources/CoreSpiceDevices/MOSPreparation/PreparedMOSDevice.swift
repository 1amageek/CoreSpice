import CoreSpiceIR
import CoreSpiceMOSContracts

/// A single-use executable owner; a copied receipt is inspection only.
public protocol PreparedMOSDevice: ~Copyable, Sendable {
    var receipt: MOSPreparationReceipt { get }
    consuming func bind(instance: Instance, context: inout BindingContext)
        throws(MOSBindingFailure) -> any BoundDevice
}

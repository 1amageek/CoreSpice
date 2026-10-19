import CoreSpiceDiodeContracts
import CoreSpiceIR

public protocol PreparedDiodeDevice: ~Copyable, Sendable {
    var receipt: DiodePreparationReceipt { get }
    consuming func bind(instance: Instance, context: inout BindingContext)
        throws(DiodePreparationFailure) -> any BoundDevice
}

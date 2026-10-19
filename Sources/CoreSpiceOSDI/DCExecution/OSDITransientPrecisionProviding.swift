import CoreSpiceDevices

/// Cold exact-model evidence retained after consuming device binding.
public protocol OSDITransientPrecisionProviding: BoundDevice {
    var transientPrecisionReceipt: OSDITransientPrecisionReceipt? { get }
}

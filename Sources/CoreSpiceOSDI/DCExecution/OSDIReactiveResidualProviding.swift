import CoreSpiceDevices

/// Immutable descriptor capability, including ground and collapsed raw rows.
public protocol OSDIReactiveResidualProviding: BoundDevice {
    /// False only when every admitted raw node advertises no reactive residual storage.
    var hasReactiveResidual: Bool { get }
}

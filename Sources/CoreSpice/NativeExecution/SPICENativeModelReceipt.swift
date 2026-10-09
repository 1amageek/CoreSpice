import CoreSpiceIR

/// Receipt published only after a complete numerical schedule executes with this selected binding.
public struct SPICENativeModelReceipt: Sendable {
    public let instanceName: String
    public let deviceType: String
    public let model: ResolvedDeviceModel?
    public let completedPointCount: Int
}

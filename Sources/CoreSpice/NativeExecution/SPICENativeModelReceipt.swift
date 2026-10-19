import CoreSpiceIR
import CoreSpiceMOSContracts
import CoreSpiceDiodeContracts

/// Receipt published only after a complete numerical schedule executes with this selected binding.
public struct SPICENativeModelReceipt: Sendable {
    public let instanceName: String
    public let deviceType: String
    public let model: ResolvedDeviceModel?
    public let mosPreparation: MOSPreparationReceipt?
    public let osdiPreparation: NativeOSDIPreparationRecord?
    public let diodePreparation: DiodePreparationReceipt?
    public let selectedModelIdentifier: String?
    public let completedPointCount: Int
}

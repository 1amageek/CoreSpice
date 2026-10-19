import CoreSpiceOSDI
import CoreSpiceMOSContracts

public enum SPICENativeExecutionError: Error, Sendable {
    case osdi(OSDIAdapterFailure)
    case osdiCleanup(SPICEOSDICleanupFailure)
    case cancelled
    case unsupportedCapability(String)
    case mosPreparation(MOSPreparationFailure)
    case numerical(any Error)
    case binding(any Error)
    case resource(any Error)
    case invalidOutput
}

import CoreSpiceOSDI
import CoreSpiceDevices
import CoreSpiceMOSContracts
import CoreSpiceDiodeContracts

public enum SPICENativePreparationError: Error, Sendable {
    case osdi(OSDIAdapterFailure)
    case osdiCleanup(SPICEOSDICleanupFailure)
    case evaluationEnvironment(OperatingConditionsError)
    case invalidLimits
    case diodePreparation(DiodePreparationFailure)
    case mosPreparation(MOSPreparationFailure)
    case mosBinding(MOSBindingFailure)
    case capacityExceeded
    case unsupportedCapability(String)
    case compile(any Error)
    case binding(any Error)
    case resource(any Error)
}

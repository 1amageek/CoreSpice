import CoreSpiceParsedIR
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution

public enum SPICESimulationPreparationError: Error, Sendable {
    case diodeResolution(DiodeResolutionFailure, resourceCause: (any Error)?, reservation: SPICESourceStorageReservation?)
    case condition(MOSConditionEvaluationFailure, resourceCause: (any Error)?)
    case resolution(MOSResolutionFailure, resourceCause: (any Error)?)
    case invalidPolicy
    case missingAnalysis
    case unsupportedCapability(String)
    case invalidSupplyBinding(String)
    case missingConditionCoverage
    case conditionMismatch
    case resource(any Error)
    case source(any Error)
    case parser(any Error)
    case lowering(any Error)
    case options(any Error)
    case nodeVoltage(SPICENodeVoltageResolutionError)
}

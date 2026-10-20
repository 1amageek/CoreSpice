import CoreSpiceOSDI

public enum NativePrescribedVoltageFlowFailure: Error, Sendable {
    public enum Phase: Sendable, Equatable { case initialValues, initialRoot, windowValues, windowChart, branchJoin, evolution, picard, scope }
    case invalidInput
    case missingControlledPreparation
    case invalidBinding
    case unsupportedProfile
    case capacityExceeded
    case cancelled
    case uncertified(Phase, cause: any Error)
    case capture(Phase, cause: OSDIConstitutiveCaptureFailure)
    case smooth(Phase, cause: OSDISmoothRangeFailure)
    case phase(Phase, cause: any Error)
}

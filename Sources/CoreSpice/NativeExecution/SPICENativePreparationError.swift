import CoreSpiceMOSContracts

public enum SPICENativePreparationError: Error, Sendable {
    case invalidLimits
    case mosPreparation(MOSPreparationFailure)
    case mosBinding(MOSBindingFailure)
    case capacityExceeded
    case unsupportedCapability(String)
    case compile(any Error)
    case binding(any Error)
    case resource(any Error)
}

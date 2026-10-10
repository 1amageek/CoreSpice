import CoreSpiceMOSContracts

public enum SPICENativeExecutionError: Error, Sendable {
    case cancelled
    case unsupportedCapability(String)
    case mosPreparation(MOSPreparationFailure)
    case numerical(any Error)
    case binding(any Error)
    case resource(any Error)
    case invalidOutput
}

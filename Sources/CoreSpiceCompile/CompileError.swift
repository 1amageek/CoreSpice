import CoreSpiceMOSContracts

/// Errors that can occur during circuit compilation.
public enum CompileError: Error, Sendable, Equatable {
    case osdiPreparationRequired(instance: String)
    case diodePreparationRequired(instance: String)
    case unexpectedMOSStage(instance: String)
    case mosPreparationRequired(instance: String)
    case mosNotPrepared(instance: String)
    case mosInstanceMismatch(instance: String, receipt: String)
    case mosReleaseMismatch(instance: String, expectedLevel: Int, actual: MOSModelRelease)
    case mosPolarityMismatch(instance: String, expected: MOSPolarity, actual: MOSPolarity)
    case mosPhysicalPortCount(instance: String, actual: Int)
    case mosNodeMissing(instance: String, node: Int)
    case unknownDeviceType(String)
    case bindingFailed(instance: String, reason: String)
    case emptyCircuit
    case singularMatrix
    case incompatibleStructure(String)
    case vectorDimensionMismatch(vector: String, expected: Int, actual: Int)
}

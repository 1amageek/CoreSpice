import OSDIContracts

/// Invalid portable integration input; runtime loading and model failures are separate.
public enum OSDIIntegrationFailure: Error, Sendable, Equatable {
    case invalidModelName
    case invalidDescriptorSelection
    case wrongAssignmentScope(name: String, expected: OSDIParameterScope, actual: OSDIParameterScope)
    case duplicateAssignment(name: String, scope: OSDIParameterScope)
    case duplicateSimulationParameter(name: String)
    case invalidPreviousState
    case invalidTemperature
    case stateDimensionMismatch(expected: Int, actual: Int)
    case duplicateResolvedParameter(index: Int, scope: OSDIParameterScope)
}

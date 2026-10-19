import OSDIContracts

/// Immutable typed instance configuration; foreign metadata is admitted during actual setup.
public struct OSDIResolvedInstance: Sendable, Equatable {
    public let binding: OSDIModelBinding
    public let instanceParameters: [OSDIParameterAssignment]
    public let previousState: [Double]

    public init(binding: OSDIModelBinding, instanceParameters: [OSDIParameterAssignment],
                previousState: [Double]) throws(OSDIIntegrationFailure) {
        var names = Set<String>()
        for assignment in instanceParameters {
            guard assignment.scope == .instance else {
                throw .wrongAssignmentScope(name: assignment.name, expected: .instance, actual: assignment.scope)
            }
            guard names.insert(assignment.name).inserted else {
                throw .duplicateAssignment(name: assignment.name, scope: .instance)
            }
        }
        guard previousState.allSatisfy(\.isFinite) else { throw .invalidPreviousState }
        self.binding = binding
        self.instanceParameters = instanceParameters
        self.previousState = previousState
    }
}

import CircuiteFoundation
import OSDIContracts

/// Exact foreign model selection and explicitly typed model-scoped assignments.
public struct OSDIModelBinding: Sendable, Equatable {
    public let modelName: String
    public let artifact: ArtifactReference
    public let descriptorIndex: Int
    public let expectedDescriptorName: String
    public let modelParameters: [OSDIParameterAssignment]

    public init(modelName: String, artifact: ArtifactReference, descriptorIndex: Int,
                expectedDescriptorName: String, modelParameters: [OSDIParameterAssignment]) throws(OSDIIntegrationFailure) {
        guard !modelName.isEmpty, !modelName.utf8.contains(0) else { throw .invalidModelName }
        guard descriptorIndex >= 0, !expectedDescriptorName.isEmpty,
              !expectedDescriptorName.utf8.contains(0) else { throw .invalidDescriptorSelection }
        var names = Set<String>()
        for assignment in modelParameters {
            guard assignment.scope == .model else {
                throw .wrongAssignmentScope(name: assignment.name, expected: .model, actual: assignment.scope)
            }
            guard names.insert(assignment.name).inserted else {
                throw .duplicateAssignment(name: assignment.name, scope: .model)
            }
        }
        self.modelName = modelName
        self.artifact = artifact
        self.descriptorIndex = descriptorIndex
        self.expectedDescriptorName = expectedDescriptorName
        self.modelParameters = modelParameters
    }
}

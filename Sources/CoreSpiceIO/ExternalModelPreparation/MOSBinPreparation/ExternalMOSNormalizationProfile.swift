import CircuiteFoundation
import CoreSpiceMOSContracts
import OSDIContracts

/// Explicit source conventions and exact foreign metadata; contains no model defaults.
public struct ExternalMOSNormalizationProfile: Sendable {
    public enum WidthConvention: String, Sendable, Equatable { case total, perFinger }
    public enum SelectionWidth: String, Sendable, Equatable { case total, perFinger, sourceFlag }
    public enum CandidateOrder: String, Sendable, Equatable { case unique, firstForward, firstReverse }
    public enum DuplicateModels: String, Sendable, Equatable { case reject, firstDeclaration }

    public let label: String
    public let artifact: ArtifactReference
    public let descriptor: OSDIDescriptorInfo
    public let parameters: [OSDIParameterInfo]
    public let sourceLevel: Int
    public let sourceVersions: [String]
    public let rules: [ExternalMOSParameterRule]
    public let nmosAssignments: [OSDIParameterAssignment]
    public let pmosAssignments: [OSDIParameterAssignment]
    public let versionParameter: String?
    public let sourceWidth: WidthConvention
    public let selectionWidth: SelectionWidth
    public let providerWidth: WidthConvention
    public let omittedFingerCount: Double?
    public let candidateOrder: CandidateOrder
    public let duplicateModels: DuplicateModels
    public let endpointToleranceSI: Double

    public init(label: String, artifact: ArtifactReference, descriptor: OSDIDescriptorInfo,
                parameters: [OSDIParameterInfo], sourceLevel: Int, sourceVersions: [String],
                rules: [ExternalMOSParameterRule], nmosAssignments: [OSDIParameterAssignment],
                pmosAssignments: [OSDIParameterAssignment], versionParameter: String?,
                sourceWidth: WidthConvention, selectionWidth: SelectionWidth,
                providerWidth: WidthConvention, omittedFingerCount: Double?,
                candidateOrder: CandidateOrder, duplicateModels: DuplicateModels,
                endpointToleranceSI: Double) {
        self.label = label; self.artifact = artifact; self.descriptor = descriptor
        self.parameters = parameters; self.sourceLevel = sourceLevel; self.sourceVersions = sourceVersions
        self.rules = rules; self.nmosAssignments = nmosAssignments; self.pmosAssignments = pmosAssignments
        self.versionParameter = versionParameter; self.sourceWidth = sourceWidth
        self.selectionWidth = selectionWidth; self.providerWidth = providerWidth
        self.omittedFingerCount = omittedFingerCount; self.candidateOrder = candidateOrder
        self.duplicateModels = duplicateModels; self.endpointToleranceSI = endpointToleranceSI
    }
}

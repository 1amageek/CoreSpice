import CoreSpiceMOSContracts

/// Immutable failure evidence. Candidate ranges require this retained snapshot owner.
public struct MOSResolutionDiagnostic: Sendable {
    public let snapshot: MOSDeclarationSnapshot
    public let cause: MOSResolutionFailure
    public let instance: String?
    public let instanceSource: MOSSourceOccurrence?
    public let invocation: UInt64?
    public let scope: MOSScopeID?
    public let modelReference: MOSSymbolID?
    public let binding: MOSSymbolID?
    public let program: MOSProgramID?
    public let rawGeometry: MOSInputGeometry?
    public let normalizedGeometry: MOSNormalizedGeometry?
    public let selectionGeometry: MOSSelectionGeometry?
    public let candidateRange: Range<Int>?
    public let candidateRangeIsFamily: Bool
    public let candidates: [MOSCandidateEvidence]
    public let isTruncated: Bool
}

import CoreSpiceMOSContracts

package struct MOSEvaluationAttempt {
    package var conditionSource: MOSSourceOccurrence?
    package var conditionDependencies: [MOSConditionDependency] = []
    package var instance: String?
    package var instanceSource: MOSSourceOccurrence?
    package var invocation: UInt64?
    package var scope: MOSScopeID?
    package var modelReference: MOSSymbolID?
    package var binding: MOSSymbolID?
    package var program: MOSProgramID?
    package var rawGeometry: MOSInputGeometry?
    package var normalizedGeometry: MOSNormalizedGeometry?
    package var selectionGeometry: MOSSelectionGeometry?
    package var candidateRange: Range<Int>?
    package var candidateRangeIsFamily = false
    package var candidates: [MOSCandidateEvidence] = []
    package var variableBytes: UInt64 = 0
    package var isTruncated = false
}

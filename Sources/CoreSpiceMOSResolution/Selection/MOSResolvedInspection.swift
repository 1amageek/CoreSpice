import CoreSpiceMOSContracts

/// Checked metadata and held selection evidence; no numerical execution admission.
public struct MOSResolvedInspection: Sendable, Hashable {
    public let declaration: MOSDeclarationID
    public let name: MOSSymbolID
    public let owningScope: MOSScopeID
    public let release: MOSModelRelease
    public let candidates: [MOSCandidateEvidence]
    package init(declaration: MOSDeclarationID, name: MOSSymbolID, owningScope: MOSScopeID,
        release: MOSModelRelease, candidates: [MOSCandidateEvidence]) {
        self.declaration = declaration; self.name = name; self.owningScope = owningScope
        self.release = release; self.candidates = candidates
    }
}

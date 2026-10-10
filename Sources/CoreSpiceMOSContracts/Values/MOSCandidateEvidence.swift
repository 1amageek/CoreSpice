public struct MOSCandidateEvidence: Sendable, Hashable {
    public let declaration: MOSDeclarationID
    public let disposition: MOSCandidateDisposition
    public let bounds: MOSBinBounds?
    public init(declaration: MOSDeclarationID, disposition: MOSCandidateDisposition, bounds: MOSBinBounds? = nil) {
        self.declaration = declaration; self.disposition = disposition; self.bounds = bounds
    }
}

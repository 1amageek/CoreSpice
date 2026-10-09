public struct MOSCandidateEvidence: Sendable, Hashable {
    public let declaration: MOSDeclarationID
    public let disposition: MOSCandidateDisposition
    public init(declaration: MOSDeclarationID, disposition: MOSCandidateDisposition) {
        self.declaration = declaration; self.disposition = disposition
    }
}

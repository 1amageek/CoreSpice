public struct CoreSpiceActionDomainOperation: Codable, Sendable, Hashable {
    public let operationID: String
    public let maturity: String
    public let inputRefs: [String]
    public let preconditions: [String]
    public let effects: [String]
    public let producedArtifacts: [String]
    public let verificationGates: [String]
    public let reversible: Bool

    public init(
        operationID: String,
        maturity: String,
        inputRefs: [String],
        preconditions: [String],
        effects: [String],
        producedArtifacts: [String],
        verificationGates: [String],
        reversible: Bool
    ) {
        self.operationID = operationID
        self.maturity = maturity
        self.inputRefs = inputRefs
        self.preconditions = preconditions
        self.effects = effects
        self.producedArtifacts = producedArtifacts
        self.verificationGates = verificationGates
        self.reversible = reversible
    }
}

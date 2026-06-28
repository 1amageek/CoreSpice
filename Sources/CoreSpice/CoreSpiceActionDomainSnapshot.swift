public struct CoreSpiceActionDomainSnapshot: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let domainID: String
    public let ownerPackages: [String]
    public let operations: [CoreSpiceActionDomainOperation]

    public init(
        schemaVersion: Int = 1,
        domainID: String,
        ownerPackages: [String],
        operations: [CoreSpiceActionDomainOperation]
    ) {
        self.schemaVersion = schemaVersion
        self.domainID = domainID
        self.ownerPackages = ownerPackages
        self.operations = operations
    }
}

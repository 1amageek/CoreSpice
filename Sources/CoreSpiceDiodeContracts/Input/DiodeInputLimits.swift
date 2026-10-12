public struct DiodeInputLimits: Sendable, Hashable {
    public let maximumAssignments: Int
    public let maximumParameterNameBytes: Int
    public init(maximumAssignments: Int, maximumParameterNameBytes: Int) throws(DiodeSchemaFailure) {
        guard maximumAssignments > 0, maximumParameterNameBytes > 0 else { throw .invalidLimits }
        self.maximumAssignments = maximumAssignments
        self.maximumParameterNameBytes = maximumParameterNameBytes
    }
}

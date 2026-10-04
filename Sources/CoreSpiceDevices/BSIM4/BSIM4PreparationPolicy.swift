import CoreSpiceCompactModels

/// Caller-selected work ceiling; distinct from physical model parameters.
public struct BSIM4PreparationPolicy: Sendable, Hashable, Codable {
    public let maximumStressIterations: UInt32
    public init(maximumStressIterations: UInt32) throws {
        guard maximumStressIterations > 0 else { throw BSIM4Error.resourceBudgetExceeded }
        self.maximumStressIterations = maximumStressIterations
    }
    private enum CodingKeys: String, CodingKey { case maximumStressIterations }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(maximumStressIterations: container.decode(UInt32.self, forKey: .maximumStressIterations))
    }
}

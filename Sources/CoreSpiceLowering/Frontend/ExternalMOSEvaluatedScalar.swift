/// Actual same-session scalar evaluation retained independently of profile claims.
public struct ExternalMOSEvaluatedScalar: Sendable, Equatable {
    public let address: ExternalMOSScalarAddress
    public let value: Double
}

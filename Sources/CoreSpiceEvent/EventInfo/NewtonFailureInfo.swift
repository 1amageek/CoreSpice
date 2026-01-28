public struct NewtonFailureInfo: Sendable {

    public let id: AnalysisID
    public let iteration: Int
    public let residualNorm: Double
    public let reason: String

    public init(
        id: AnalysisID,
        iteration: Int,
        residualNorm: Double,
        reason: String
    ) {
        self.id = id
        self.iteration = iteration
        self.residualNorm = residualNorm
        self.reason = reason
    }
}

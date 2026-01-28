public struct NewtonResultInfo: Sendable {

    public let id: AnalysisID
    public let iteration: Int
    public let residualNorm: Double
    public let damping: Double
    public let converged: Bool

    public init(
        id: AnalysisID,
        iteration: Int,
        residualNorm: Double,
        damping: Double,
        converged: Bool
    ) {
        self.id = id
        self.iteration = iteration
        self.residualNorm = residualNorm
        self.damping = damping
        self.converged = converged
    }
}

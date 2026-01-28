public struct SweepPointResultInfo: Sendable {

    public let id: AnalysisID
    public let index: Int
    public let value: Double
    public let parameterName: String
    public let converged: Bool
    public let iterations: Int

    public init(
        id: AnalysisID,
        index: Int,
        value: Double,
        parameterName: String,
        converged: Bool,
        iterations: Int
    ) {
        self.id = id
        self.index = index
        self.value = value
        self.parameterName = parameterName
        self.converged = converged
        self.iterations = iterations
    }
}

public struct NewtonInfo: Sendable {

    public let id: AnalysisID
    public let iteration: Int
    public let maxIterations: Int

    public init(id: AnalysisID, iteration: Int, maxIterations: Int) {
        self.id = id
        self.iteration = iteration
        self.maxIterations = maxIterations
    }
}

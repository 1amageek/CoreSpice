public struct TimeStepInfo: Sendable {

    public let id: AnalysisID
    public let time: Double
    public let timeStep: Double
    public let iterations: Int
    public let lte: Double

    public init(
        id: AnalysisID,
        time: Double,
        timeStep: Double,
        iterations: Int,
        lte: Double
    ) {
        self.id = id
        self.time = time
        self.timeStep = timeStep
        self.iterations = iterations
        self.lte = lte
    }
}

public struct ProgressInfo: Sendable {

    public let id: AnalysisID
    public let fraction: Double
    public let message: String

    public init(id: AnalysisID, fraction: Double, message: String) {
        precondition(
            fraction >= 0.0 && fraction <= 1.0,
            "fraction must be in 0...1, got \(fraction)"
        )
        self.id = id
        self.fraction = fraction
        self.message = message
    }
}

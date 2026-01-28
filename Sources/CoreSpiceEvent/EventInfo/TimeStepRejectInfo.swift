public struct TimeStepRejectInfo: Sendable {

    public let id: AnalysisID
    public let time: Double
    public let rejectedStep: Double
    public let newStep: Double
    public let reason: String

    public init(
        id: AnalysisID,
        time: Double,
        rejectedStep: Double,
        newStep: Double,
        reason: String
    ) {
        self.id = id
        self.time = time
        self.rejectedStep = rejectedStep
        self.newStep = newStep
        self.reason = reason
    }
}

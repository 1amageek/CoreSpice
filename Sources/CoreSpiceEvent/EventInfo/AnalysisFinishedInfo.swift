public struct AnalysisFinishedInfo: Sendable {

    public let id: AnalysisID
    public let type: AnalysisType
    public let status: AnalysisStatus
    public let timestamp: Timestamp
    public let wallTime: Duration
    public let failure: AnalysisFailureInfo?

    public init(
        id: AnalysisID,
        type: AnalysisType,
        status: AnalysisStatus,
        timestamp: Timestamp,
        wallTime: Duration,
        failure: AnalysisFailureInfo? = nil
    ) {
        self.id = id
        self.type = type
        self.status = status
        self.timestamp = timestamp
        self.wallTime = wallTime
        self.failure = failure
    }
}

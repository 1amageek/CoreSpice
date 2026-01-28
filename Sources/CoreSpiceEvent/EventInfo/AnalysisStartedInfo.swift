public struct AnalysisStartedInfo: Sendable {

    public let id: AnalysisID
    public let type: AnalysisType
    public let timestamp: Timestamp
    public let nodeCount: Int
    public let deviceCount: Int

    public init(
        id: AnalysisID,
        type: AnalysisType,
        timestamp: Timestamp,
        nodeCount: Int,
        deviceCount: Int
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.nodeCount = nodeCount
        self.deviceCount = deviceCount
    }
}

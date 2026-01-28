public struct GpuDispatchResultInfo: Sendable {

    public let id: AnalysisID
    public let kernelName: String
    public let elapsedTime: Duration
    public let tag: String

    public init(
        id: AnalysisID,
        kernelName: String,
        elapsedTime: Duration,
        tag: String
    ) {
        self.id = id
        self.kernelName = kernelName
        self.elapsedTime = elapsedTime
        self.tag = tag
    }
}

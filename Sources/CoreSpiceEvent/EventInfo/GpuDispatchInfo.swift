public struct GpuDispatchInfo: Sendable {

    public let id: AnalysisID
    public let kernelName: String
    public let gridSize: GridDimensions
    public let tag: String

    public init(
        id: AnalysisID,
        kernelName: String,
        gridSize: GridDimensions,
        tag: String
    ) {
        self.id = id
        self.kernelName = kernelName
        self.gridSize = gridSize
        self.tag = tag
    }
}

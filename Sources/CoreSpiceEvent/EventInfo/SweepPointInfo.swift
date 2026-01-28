public struct SweepPointInfo: Sendable {

    public let id: AnalysisID
    public let index: Int
    public let total: Int
    public let value: Double
    public let parameterName: String

    public init(
        id: AnalysisID,
        index: Int,
        total: Int,
        value: Double,
        parameterName: String
    ) {
        self.id = id
        self.index = index
        self.total = total
        self.value = value
        self.parameterName = parameterName
    }
}

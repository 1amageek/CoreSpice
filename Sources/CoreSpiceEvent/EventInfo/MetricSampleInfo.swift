public struct MetricSampleInfo: Sendable {

    public let id: AnalysisID
    public let name: String
    public let value: Double
    public let unit: String

    public init(id: AnalysisID, name: String, value: Double, unit: String) {
        self.id = id
        self.name = name
        self.value = value
        self.unit = unit
    }
}

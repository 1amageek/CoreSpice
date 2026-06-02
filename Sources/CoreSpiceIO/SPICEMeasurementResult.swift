import CoreSpiceParsedIR

/// A structured result from a `.measure` directive.
public struct SPICEMeasurementResult: Sendable, Hashable, Codable {

    public let analysisType: OutputAnalysisType
    public let name: String
    public let value: Double
    public let unit: String

    public init(
        analysisType: OutputAnalysisType,
        name: String,
        value: Double,
        unit: String
    ) {
        self.analysisType = analysisType
        self.name = name
        self.value = value
        self.unit = unit
    }
}

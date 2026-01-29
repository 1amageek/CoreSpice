import Foundation

/// Metadata about a simulation run.
///
/// Captures information about when and how the simulation was performed,
/// useful for documentation and result tracking.
public struct SimulationMetadata: Sendable, Codable {

    /// The title from the netlist.
    public let title: String?

    /// The date and time when the simulation was run.
    public let date: Date

    /// The tool name that performed the simulation.
    public let tool: String

    /// The tool version.
    public let toolVersion: String?

    /// The type of analysis performed.
    public let analysisType: AnalysisKind

    /// The simulation temperature in Celsius.
    public let temperature: Double?

    /// The number of data points.
    public let pointCount: Int

    /// The number of variables.
    public let variableCount: Int

    /// Whether the data is real or complex.
    public let isComplex: Bool

    /// Additional options used in the simulation.
    public let options: [String: String]

    public init(
        title: String? = nil,
        date: Date = Date(),
        tool: String = "CoreSpice",
        toolVersion: String? = nil,
        analysisType: AnalysisKind,
        temperature: Double? = nil,
        pointCount: Int,
        variableCount: Int,
        isComplex: Bool = false,
        options: [String: String] = [:]
    ) {
        self.title = title
        self.date = date
        self.tool = tool
        self.toolVersion = toolVersion
        self.analysisType = analysisType
        self.temperature = temperature
        self.pointCount = pointCount
        self.variableCount = variableCount
        self.isComplex = isComplex
        self.options = options
    }
}

extension SimulationMetadata: CustomStringConvertible {
    public var description: String {
        var parts = ["\(tool) \(analysisType.rawValue) analysis"]
        if let t = title {
            parts.append("'\(t)'")
        }
        parts.append("\(pointCount) points, \(variableCount) variables")
        if isComplex {
            parts.append("(complex)")
        }
        return parts.joined(separator: " - ")
    }
}

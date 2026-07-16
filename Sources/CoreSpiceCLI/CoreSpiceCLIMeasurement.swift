/// One evaluated `.measure` result.
public struct CoreSpiceCLIMeasurement: Codable, Sendable, Hashable {
  public let analysis: String
  public let name: String
  public let value: Double
  public let unit: String?

  public init(analysis: String, name: String, value: Double, unit: String?) {
    self.analysis = analysis
    self.name = name
    self.value = value
    self.unit = unit
  }
}

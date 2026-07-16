/// Basic statistics for a waveform produced or consumed by the CLI.
public struct CoreSpiceCLIWaveformSummary: Codable, Sendable, Hashable {
  public let variables: [String]
  public let points: Int
  public let runs: Int?

  public init(variables: [String], points: Int, runs: Int? = nil) {
    self.variables = variables
    self.points = points
    self.runs = runs
  }
}

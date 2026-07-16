import CircuiteFoundation

/// Reproducible machine-readable record for one post-hoc measurement run.
public struct CoreSpiceCLIMeasurementRunRecord: Codable, Sendable, Hashable {
  public let schemaVersion: SchemaVersion
  public let status: String
  public let invocation: ExecutionInvocation
  public let inputArtifact: ArtifactReference
  public let measurements: [CoreSpiceCLIMeasurement]
  public let waveform: CoreSpiceCLIWaveformSummary

  public init(
    invocation: ExecutionInvocation,
    inputArtifact: ArtifactReference,
    measurements: [CoreSpiceCLIMeasurement],
    waveform: CoreSpiceCLIWaveformSummary
  ) {
    self.schemaVersion = .v1
    self.status = "succeeded"
    self.invocation = invocation
    self.inputArtifact = inputArtifact
    self.measurements = measurements
    self.waveform = waveform
  }
}

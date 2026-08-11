import CircuiteFoundation

/// Reproducible machine-readable record for one completed batch simulation.
public struct CoreSpiceCLIBatchRunRecord: Codable, Sendable, Hashable {
  public let schemaVersion: SchemaVersion
  public let status: String
  public let producer: ProducerIdentity
  public let invocation: ExecutionInvocation
  public let inputArtifacts: [ArtifactReference]
  public let outputArtifacts: [ArtifactReference]
  public let analyses: [String]
  public let measurements: [CoreSpiceCLIMeasurement]
  public let waveform: CoreSpiceCLIWaveformSummary?

  public init(
    producer: ProducerIdentity,
    invocation: ExecutionInvocation,
    inputArtifacts: [ArtifactReference],
    outputArtifacts: [ArtifactReference],
    analyses: [String],
    measurements: [CoreSpiceCLIMeasurement],
    waveform: CoreSpiceCLIWaveformSummary?
  ) {
    self.schemaVersion = .v1
    self.status = "succeeded"
    self.producer = producer
    self.invocation = invocation
    self.inputArtifacts = inputArtifacts
    self.outputArtifacts = outputArtifacts
    self.analyses = analyses
    self.measurements = measurements
    self.waveform = waveform
  }
}

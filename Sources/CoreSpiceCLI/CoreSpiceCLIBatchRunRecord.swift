import CircuiteFoundation
import CoreSpiceDevices

/// Reproducible machine-readable record for one completed batch simulation.
public struct CoreSpiceCLIBatchRunRecord: Codable, Sendable, Hashable {
  public let schemaVersion: SchemaVersion
  public let resolutionProfile: String
  public let resolutionSeed: UInt64
  public let resolutionPolicy: String
  public let status: String
  public let producer: ProducerIdentity
  public let invocation: ExecutionInvocation
  public let inputArtifacts: [ArtifactReference]
  public let outputArtifacts: [ArtifactReference]
  public let analyses: [String]
  public let measurements: [CoreSpiceCLIMeasurement]
  public let bsim4NoisePreparationRequested: Bool
  public let bsim4PreparationPolicy: BSIM4PreparationPolicy?
  public let bsim4Models: [CoreSpiceCLIBSIM4Record]
  public let waveform: CoreSpiceCLIWaveformSummary?

  public init(
    producer: ProducerIdentity,
    resolutionProfile: String,
    resolutionSeed: UInt64,
    resolutionPolicy: String,
    invocation: ExecutionInvocation,
    inputArtifacts: [ArtifactReference],
    outputArtifacts: [ArtifactReference],
    analyses: [String],
    measurements: [CoreSpiceCLIMeasurement],
    waveform: CoreSpiceCLIWaveformSummary?,
    bsim4PreparationPolicy: BSIM4PreparationPolicy? = nil,
    bsim4NoisePreparationRequested: Bool = false,
    bsim4Models: [CoreSpiceCLIBSIM4Record] = []
  ) {
    self.resolutionProfile = resolutionProfile
    self.resolutionSeed = resolutionSeed
    self.resolutionPolicy = resolutionPolicy
    self.bsim4NoisePreparationRequested = bsim4NoisePreparationRequested
    self.bsim4PreparationPolicy = bsim4PreparationPolicy
    self.bsim4Models = bsim4Models
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

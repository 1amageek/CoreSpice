import CircuiteFoundation
import CoreSpice
import Foundation
import CoreSpiceCompile

/// Reproducible machine-readable record for one completed batch simulation.
public struct CoreSpiceCLIBatchRunRecord: Codable, Sendable, Hashable {
  public let solverIdentity: String?
  public let executionProfile: CoreSpiceCLIExecutionProfile?
  public let executionProfileReference: ArtifactReference?
  public let sourceInputIdentity: String?
  public let configurationIdentity: String?
  public let schemaVersion: SchemaVersion
  public let diodeResolutionProfile: String
  public let nativeDCResult: SPICENativeStoredDCResult?
  public let osdiExecution: CoreSpiceCLIOSDIExecutionRecord?
  public let osdiVariables: [CoreSpiceCLIOSDIVariableRecord]?
  public let osdiModels: [CoreSpiceCLIOSDIRecord]?
  public let diodeModels: [CoreSpiceCLIDiodeRecord]
  public let resolutionProfile: String
  public let resolutionSeed: UInt64
  public let resolutionPolicy: String
  public let status: String
  public let producer: ProducerIdentity
  public let invocation: ExecutionInvocation
  public let inputArtifacts: [ArtifactReference]
  public let outputArtifacts: [ArtifactReference]
  public let analyses: [String]
  public let analysisCompletions: [CoreSpiceCLIAnalysisCompletion]?
  public let measurements: [CoreSpiceCLIMeasurement]
  public let waveform: CoreSpiceCLIWaveformSummary?

  private enum RemovedNativeKeys: String, CodingKey {
    case bsim4Models, bsim45Models, bsim4NoisePreparationRequested, bsim4PreparationPolicy
  }

  // Old OSDI records encoded empty native metadata; this input-only check never restores a native backend.
  private static func validateRemovedNativeEvidence(_ decoder: any Decoder) throws {
    let legacy = try decoder.container(keyedBy: RemovedNativeKeys.self)
    do {
      for key in [RemovedNativeKeys.bsim4Models, .bsim45Models] where legacy.contains(key) {
        let values = try legacy.nestedUnkeyedContainer(forKey: key)
        guard values.isAtEnd else {
          throw DecodingError.dataCorruptedError(forKey: key, in: legacy,
            debugDescription: "Native BSIM execution was removed; nonempty native model evidence requires migration to OSDI")
        }
      }
      if legacy.contains(.bsim4NoisePreparationRequested) {
        // The former flag recorded parsed .noise intent for OSDI too, rather than native execution.
        _ = try legacy.decode(Bool.self, forKey: .bsim4NoisePreparationRequested)
      }
      if legacy.contains(.bsim4PreparationPolicy) {
        guard try legacy.decodeNil(forKey: .bsim4PreparationPolicy) else {
          throw DecodingError.dataCorruptedError(forKey: .bsim4PreparationPolicy, in: legacy,
            debugDescription: "Native BSIM execution was removed; native preparation policy requires migration to OSDI")
        }
      }
    } catch {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
        debugDescription: "Removed native BSIM backend evidence is unsupported; only empty model arrays, typed analysis intent and absent native policy from current OSDI records are accepted",
        underlyingError: error))
    }
  }

  public init(
    producer: ProducerIdentity,
    solverIdentity: String? = nil,
    executionProfile: CoreSpiceCLIExecutionProfile? = nil,
    executionProfileReference: ArtifactReference? = nil,
    resolutionProfile: String,
    diodeResolutionProfile: String = "genericDiodeV1",
    diodeModels: [CoreSpiceCLIDiodeRecord] = [],
    osdiModels: [CoreSpiceCLIOSDIRecord]? = nil,
    osdiVariables: [CoreSpiceCLIOSDIVariableRecord]? = nil,
    osdiExecution: CoreSpiceCLIOSDIExecutionRecord? = nil,
    nativeDCResult: SPICENativeStoredDCResult? = nil,
    resolutionSeed: UInt64,
    resolutionPolicy: String,
    invocation: ExecutionInvocation,
    inputArtifacts: [ArtifactReference],
    outputArtifacts: [ArtifactReference],
    analyses: [String],
    analysisCompletions: [CoreSpiceCLIAnalysisCompletion]? = nil,
    measurements: [CoreSpiceCLIMeasurement],
    waveform: CoreSpiceCLIWaveformSummary?
  ) {
    self.solverIdentity = solverIdentity
    self.executionProfile = executionProfile; self.executionProfileReference = executionProfileReference
    self.sourceInputIdentity = osdiExecution?.precision?.sourceInputIdentity
    self.configurationIdentity = osdiExecution?.precision?.configurationSHA256
    self.nativeDCResult = nativeDCResult
    self.osdiExecution = osdiExecution
    self.osdiVariables = osdiVariables
    self.osdiModels = osdiModels
    self.diodeResolutionProfile = diodeResolutionProfile; self.diodeModels = diodeModels
    self.resolutionProfile = resolutionProfile
    self.resolutionSeed = resolutionSeed
    self.resolutionPolicy = resolutionPolicy
    self.schemaVersion = analysisCompletions?.contains(where: { $0.analysis == "network" }) == true ? .init(major: 8, minor: 0, patch: 0) : analysisCompletions != nil ? .init(major: analysisCompletions?.count == 1 ? 7 : 6, minor: 0, patch: 0) : nativeDCResult != nil ? .init(major: 5, minor: 0, patch: 0) : osdiExecution?.precision == nil ? .v3 : .init(major: 4, minor: 0, patch: 0)
    self.status = "succeeded"
    self.producer = producer
    self.invocation = invocation
    self.inputArtifacts = inputArtifacts
    self.outputArtifacts = outputArtifacts
    self.analyses = analyses
    self.analysisCompletions = analysisCompletions
    self.measurements = measurements
    self.waveform = waveform
  }
  public init(from decoder: any Decoder) throws {
    try Self.validateRemovedNativeEvidence(decoder)
    let c = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try c.decode(SchemaVersion.self, forKey: .schemaVersion)
    guard [SchemaVersion.v3, .init(major: 4, minor: 0, patch: 0), .init(major: 5, minor: 0, patch: 0),
           .init(major: 6, minor: 0, patch: 0), .init(major: 7, minor: 0, patch: 0), .init(major: 8, minor: 0, patch: 0)].contains(schemaVersion) else {
      throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c, debugDescription: "Unsupported batch schema version")
    }
    solverIdentity = try c.decodeIfPresent(String.self, forKey: .solverIdentity)
    executionProfile = try c.decodeIfPresent(CoreSpiceCLIExecutionProfile.self, forKey: .executionProfile)
    executionProfileReference = try c.decodeIfPresent(ArtifactReference.self, forKey: .executionProfileReference)
    try CoreSpiceCLIExecutionProfile.validateSaved(executionProfile, reference: executionProfileReference,
      hasPrecisionBudget: schemaVersion == SchemaVersion(major: 4, minor: 0, patch: 0))
    guard solverIdentity == nil || solverIdentity == SparseLUSolver.implementationIdentity else {
      throw DecodingError.dataCorruptedError(forKey: .solverIdentity, in: c, debugDescription: "Unsupported saved solver identity")
    }
    sourceInputIdentity = try c.decodeIfPresent(String.self, forKey: .sourceInputIdentity)
    configurationIdentity = try c.decodeIfPresent(String.self, forKey: .configurationIdentity)
    diodeResolutionProfile = try c.decode(String.self, forKey: .diodeResolutionProfile)
    diodeModels = try c.decode([CoreSpiceCLIDiodeRecord].self, forKey: .diodeModels)
    resolutionProfile = try c.decode(String.self, forKey: .resolutionProfile)
    resolutionSeed = try c.decode(UInt64.self, forKey: .resolutionSeed)
    resolutionPolicy = try c.decode(String.self, forKey: .resolutionPolicy)
    status = try c.decode(String.self, forKey: .status)
    producer = try c.decode(ProducerIdentity.self, forKey: .producer)
    invocation = try c.decode(ExecutionInvocation.self, forKey: .invocation)
    inputArtifacts = try c.decode([ArtifactReference].self, forKey: .inputArtifacts)
    if let executionProfileReference, !inputArtifacts.contains(executionProfileReference) {
      throw CoreSpiceCLIExecutionProfile.Failure.invalidProfile("Saved batch omits the execution profile input artifact")
    }
    outputArtifacts = try c.decode([ArtifactReference].self, forKey: .outputArtifacts)
    analyses = try c.decode([String].self, forKey: .analyses)
    analysisCompletions = try c.decodeIfPresent([CoreSpiceCLIAnalysisCompletion].self, forKey: .analysisCompletions)
    measurements = try c.decode([CoreSpiceCLIMeasurement].self, forKey: .measurements)
    waveform = try c.decodeIfPresent(CoreSpiceCLIWaveformSummary.self, forKey: .waveform)
    osdiModels = try c.decodeIfPresent([CoreSpiceCLIOSDIRecord].self, forKey: .osdiModels)
    osdiVariables = try c.decodeIfPresent([CoreSpiceCLIOSDIVariableRecord].self, forKey: .osdiVariables)
    nativeDCResult = try c.decodeIfPresent(SPICENativeStoredDCResult.self, forKey: .nativeDCResult)
    osdiExecution = try c.decodeIfPresent(CoreSpiceCLIOSDIExecutionRecord.self, forKey: .osdiExecution)
    if let analysisCompletions {
      guard [SchemaVersion(major: 6, minor: 0, patch: 0), .init(major: 7, minor: 0, patch: 0), .init(major: 8, minor: 0, patch: 0)].contains(schemaVersion), status == "succeeded",
            (schemaVersion.major == 8 ? analysisCompletions.contains { $0.analysis == "network" } : schemaVersion.major == 6 ? analysisCompletions.count > 1 : analysisCompletions.count == 1 && analysisCompletions[0].preparedCompletionJSON != nil),
            (schemaVersion.major == 8) == analysisCompletions.contains(where: { $0.analysis == "network" }), analysisCompletions.map(\.analysis) == analyses,
            waveform == analysisCompletions.last?.waveform, nativeDCResult == nil,
            osdiExecution == nil, osdiModels == nil, osdiVariables == nil,
            sourceInputIdentity == nil, configurationIdentity == nil else {
        throw CoreSpiceCLIOSDIError.incompleteReceipt("Saved declared-analysis completion set differs")
      }
      for completion in analysisCompletions {
        try completion.validate()
        if completion.preparedCompletionJSON != nil, let artifact = completion.preparedCompletionArtifact {
          guard let nested = completion.preparedRecord else { throw CoreSpiceCLICaseError.incompleteOutput("Missing validated nested source completion") }
          guard let sources = nested.sensitivityEvidence?.sourceArtifacts ?? nested.transferFunction?.sourceArtifacts ?? nested.network?.sourceArtifacts,
                sources.allSatisfy({ inputArtifacts.contains($0) }),
                (nested.osdiModels ?? []).allSatisfy({ inputArtifacts.contains($0.artifact) }),
                (nested.sensitivityEvidence?.children ?? []).allSatisfy({ child in child.source.osdiModels.allSatisfy { inputArtifacts.contains($0.artifact) } }),
                outputArtifacts.contains(artifact) else {
            throw CoreSpiceCLICaseError.incompleteOutput("Outer source captures or completion artifact differ")
          }
        }
      }
      return
    }
    guard schemaVersion != SchemaVersion(major: 6, minor: 0, patch: 0), schemaVersion != SchemaVersion(major: 7, minor: 0, patch: 0), schemaVersion != SchemaVersion(major: 8, minor: 0, patch: 0) else {
      throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing declared-analysis completion set")
    }
    guard (schemaVersion == SchemaVersion(major: 5, minor: 0, patch: 0)) == (nativeDCResult != nil) else {
      throw SPICENativeStoredDCResult.Failure.invalidState
    }
    if let nativeDCResult {
      guard status == "succeeded", analyses == [nativeDCResult.analysis],
            waveform?.points == nativeDCResult.points.count, waveform?.runs == nil,
            nativeDCResult.points.contains(where: { $0.representation == .compensated }) else {
        throw SPICENativeStoredDCResult.Failure.invalidState
      }
    }
    if let osdiExecution {
      guard let osdiModels, osdiVariables == nil, status == "succeeded", analyses == [osdiExecution.analysis], waveform?.points == osdiExecution.coordinates.count else {
        throw CoreSpiceCLIOSDIError.incompleteReceipt("Saved dynamic completion does not match execution")
      }
      try osdiExecution.validate(models: osdiModels)
      if let precision = osdiExecution.precision {
        guard diodeModels.isEmpty,
              schemaVersion == SchemaVersion(major: 4, minor: 0, patch: 0),
              sourceInputIdentity == precision.sourceInputIdentity, configurationIdentity == precision.configurationSHA256 else {
          throw CoreSpiceCLIOSDIError.incompleteReceipt("Batch precision identity or envelope differs")
        }
      } else if schemaVersion == SchemaVersion(major: 4, minor: 0, patch: 0) {
        throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing precision execution in version4 envelope")
      }
    } else {
      guard schemaVersion != SchemaVersion(major: 4, minor: 0, patch: 0), sourceInputIdentity == nil, configurationIdentity == nil else {
        throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing precision execution evidence")
      }
      try CoreSpiceCLIOSDIVariableRecord.validate(models: osdiModels, variables: osdiVariables)
    }
    if osdiModels != nil && osdiExecution == nil {
      guard status == "succeeded", analyses == ["op"], waveform?.points == 1 else {
        throw CoreSpiceCLIOSDIError.incompleteReceipt("Saved OSDI completion has no matching operating point")
      }
    }
  }

}

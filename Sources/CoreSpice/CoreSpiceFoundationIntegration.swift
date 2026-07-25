import CircuiteFoundation

/// Canonical inputs for a CoreSpice execution.
///
/// The simulation implementation remains in the analysis targets. This value
/// gives callers a stable, artifact-oriented boundary while keeping simulator
/// details in the injected executor.
public struct CoreSpiceSimulationRequest: Sendable, Hashable, Codable {
  public let inputs: [ArtifactReference]
  /// The input artifact that contains the root SPICE deck.
  ///
  /// A backend may infer the primary input only when exactly one SPICE
  /// netlist input is present.
  public let primaryInputID: ArtifactID?
  public let configurationDigest: ContentDigest?
  public let designRevision: ContentDigest?
  public let randomSeed: UInt64?

  public init(
    inputs: [ArtifactReference] = [],
    primaryInputID: ArtifactID? = nil,
    configurationDigest: ContentDigest? = nil,
    designRevision: ContentDigest? = nil,
    randomSeed: UInt64? = nil
  ) {
    self.inputs = inputs
    self.primaryInputID = primaryInputID
    self.configurationDigest = configurationDigest
    self.designRevision = designRevision
    self.randomSeed = randomSeed
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      inputs: try container.decode([ArtifactReference].self, forKey: .inputs),
      primaryInputID: try container.decodeIfPresent(ArtifactID.self, forKey: .primaryInputID),
      configurationDigest: try container.decodeIfPresent(
        ContentDigest.self,
        forKey: .configurationDigest
      ),
      designRevision: try container.decodeIfPresent(
        ContentDigest.self,
        forKey: .designRevision
      ),
      randomSeed: try container.decodeIfPresent(UInt64.self, forKey: .randomSeed)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case inputs
    case primaryInputID
    case configurationDigest
    case designRevision
    case randomSeed
  }
}

/// Evidence and diagnostics emitted by one CoreSpice execution.
public struct CoreSpiceSimulationResult: Sendable, Hashable, Codable, ArtifactProducing,
  DiagnosticReporting, EvidenceProviding
{
  public let artifacts: [ArtifactReference]
  public let diagnostics: [DesignDiagnostic]
  public let evidence: EvidenceManifest

  public var provenance: ExecutionProvenance { evidence.provenance }

  public init(
    artifacts: [ArtifactReference],
    diagnostics: [DesignDiagnostic] = [],
    provenance: ExecutionProvenance
  ) {
    self.artifacts = artifacts
    self.diagnostics = diagnostics
    self.evidence = EvidenceManifest(
      provenance: provenance,
      artifacts: artifacts
    )
  }

  public init(
    request: CoreSpiceSimulationRequest,
    execution: CoreSpiceSimulationExecution,
    producer: ProducerIdentity,
    supportingTools: [ProducerIdentity] = []
  ) throws {
    try self.init(
      artifacts: execution.artifacts,
      diagnostics: execution.diagnostics,
      provenance: ExecutionProvenance(
        producer: producer,
        supportingTools: supportingTools,
        inputs: request.inputs,
        invocation: execution.invocation,
        environment: execution.environment,
        configurationDigest: request.configurationDigest,
        designRevision: request.designRevision,
        randomSeed: request.randomSeed,
        startedAt: execution.startedAt,
        completedAt: execution.completedAt
      )
    )
  }
}

/// Protocol boundary for simulator implementations that can participate in
/// the cross-package execution contract.
public protocol CoreSpiceSimulating: Engine
where Request == CoreSpiceSimulationRequest, Output == CoreSpiceSimulationResult {}

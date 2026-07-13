import CircuiteFoundation

/// Canonical inputs for a CoreSpice execution.
///
/// The simulation implementation remains in the analysis targets. This value
/// gives callers a stable, artifact-oriented boundary while keeping simulator
/// details in the injected execution adapter.
public struct CoreSpiceSimulationRequest: Sendable, Hashable, Codable {
  public let inputs: [ArtifactReference]
  public let configurationDigest: ContentDigest?
  public let designRevision: ContentDigest?
  public let randomSeed: UInt64?

  public init(
    inputs: [ArtifactReference] = [],
    configurationDigest: ContentDigest? = nil,
    designRevision: ContentDigest? = nil,
    randomSeed: UInt64? = nil
  ) {
    self.inputs = inputs
    self.configurationDigest = configurationDigest
    self.designRevision = designRevision
    self.randomSeed = randomSeed
  }
}

/// Evidence and diagnostics emitted by one CoreSpice execution.
public struct CoreSpiceSimulationResult: Sendable, Hashable, Codable, ArtifactProducing,
  DiagnosticReporting, EvidenceProviding
{
  public let artifacts: [ArtifactReference]
  public let diagnostics: [DesignDiagnostic]
  public let evidence: EvidenceManifest

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
}

/// Protocol boundary for simulator implementations that can participate in
/// the cross-package execution contract.
public protocol CoreSpiceSimulationEngine: Engine
where Request == CoreSpiceSimulationRequest, Output == CoreSpiceSimulationResult {}

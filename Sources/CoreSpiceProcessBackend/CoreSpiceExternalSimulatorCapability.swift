import CircuiteFoundation

/// Machine-readable capability and executable identity for an external
/// simulator adapter.
public struct CoreSpiceExternalSimulatorCapability: Sendable, Hashable, Codable {
    public let simulator: ProducerIdentity
    public let executable: ArtifactReference
    public let supportedMOSModelLevels: [Int]
    public let supportedAnalyses: [CoreSpiceExternalAnalysis]
    public let controlsRandomSeed: Bool
    public let reportsExactConsumedInputs: Bool

    public init(
        simulator: ProducerIdentity,
        executable: ArtifactReference,
        supportedMOSModelLevels: [Int],
        supportedAnalyses: [CoreSpiceExternalAnalysis],
        controlsRandomSeed: Bool,
        reportsExactConsumedInputs: Bool
    ) {
        self.simulator = simulator
        self.executable = executable
        self.supportedMOSModelLevels = supportedMOSModelLevels
        self.supportedAnalyses = supportedAnalyses
        self.controlsRandomSeed = controlsRandomSeed
        self.reportsExactConsumedInputs = reportsExactConsumedInputs
    }

    public func supports(
        mosModelLevel: Int,
        analysis: CoreSpiceExternalAnalysis
    ) -> Bool {
        supportedMOSModelLevels.contains(mosModelLevel)
            && supportedAnalyses.contains(analysis)
    }
}

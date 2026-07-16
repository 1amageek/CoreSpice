import CircuiteFoundation
import Foundation

public struct CoreSpiceSimulationExecution: Sendable, Hashable, Codable {
    public let artifacts: [ArtifactReference]
    public let diagnostics: [DesignDiagnostic]
    public let invocation: ExecutionInvocation
    public let environment: ExecutionEnvironmentFingerprint
    public let startedAt: Date
    public let completedAt: Date

    public init(
        artifacts: [ArtifactReference],
        diagnostics: [DesignDiagnostic] = [],
        invocation: ExecutionInvocation,
        environment: ExecutionEnvironmentFingerprint,
        startedAt: Date,
        completedAt: Date
    ) throws {
        let startInterval = startedAt.timeIntervalSinceReferenceDate
        let completionInterval = completedAt.timeIntervalSinceReferenceDate
        guard startInterval.isFinite else {
            throw CoreSpiceSimulationExecutionError.nonFiniteTimestamp(
                kind: "start",
                value: startInterval
            )
        }
        guard completionInterval.isFinite else {
            throw CoreSpiceSimulationExecutionError.nonFiniteTimestamp(
                kind: "completion",
                value: completionInterval
            )
        }
        guard completedAt >= startedAt else {
            throw CoreSpiceSimulationExecutionError.completionPrecedesStart(
                startedAt: startedAt,
                completedAt: completedAt
            )
        }

        self.artifacts = artifacts
        self.diagnostics = diagnostics
        self.invocation = invocation
        self.environment = environment
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

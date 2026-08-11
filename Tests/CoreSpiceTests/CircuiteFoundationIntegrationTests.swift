import CoreSpice
import CircuiteFoundation
import Foundation
import Testing

@Suite
struct CircuiteFoundationIntegrationTests {
    @Test
    func defaultEngineProducesFoundationEvidenceWithExactExecutionMetadata() async throws {
        let input = try artifactReference(path: "inputs/circuit.spice", role: .input, byteCount: 12)
        let output = try artifactReference(path: "outputs/waveform.raw", role: .output, byteCount: 24)
        let startedAt = Date(timeIntervalSince1970: 100)
        let completedAt = Date(timeIntervalSince1970: 101)
        let invocation = try ExecutionInvocation.inProcess(entryPoint: "CoreSpiceAnalysis")
        let environment = try ExecutionEnvironmentFingerprint(
            platform: "macOS",
            architecture: "arm64",
            toolchain: "Swift-6.3"
        )
        let execution = try CoreSpiceSimulationExecution(
            artifacts: [output],
            diagnostics: [],
            invocation: invocation,
            environment: environment,
            startedAt: startedAt,
            completedAt: completedAt
        )
        let producer = try ProducerIdentity(
            kind: .engine,
            identifier: "CoreSpice",
            version: "1.0.0"
        )
        let backend = FixedSimulationBackend(execution: execution)
        let engine = CoreSpiceSimulator(
            backend: backend,
            producer: producer
        )
        let request = CoreSpiceSimulationRequest(
            inputs: [input],
            randomSeed: 7
        )

        let result = try await engine.execute(request)

        #expect(result.artifacts == [output])
        #expect(result.evidence.artifacts == [output])
        #expect(result.provenance == result.evidence.provenance)
        #expect(result.evidence.provenance.inputs == [input])
        #expect(result.evidence.provenance.invocation == invocation)
        #expect(result.evidence.provenance.environment == environment)
        #expect(result.evidence.provenance.randomSeed == 7)
        #expect(
            result.evidence.provenance.startedAt.secondsSinceUnixEpoch
                == startedAt.timeIntervalSince1970
        )
        #expect(
            result.evidence.provenance.completedAt.secondsSinceUnixEpoch
                == completedAt.timeIntervalSince1970
        )
    }

    @Test
    func executionRejectsAnImpossibleTimeline() {
        #expect(throws: CoreSpiceSimulationExecutionError.self) {
            try CoreSpiceSimulationExecution(
                artifacts: [],
                invocation: ExecutionInvocation.inProcess(entryPoint: "CoreSpiceAnalysis"),
                environment: ExecutionEnvironmentFingerprint(
                    platform: "macOS",
                    architecture: "arm64",
                    toolchain: "Swift-6.3"
                ),
                startedAt: Date(timeIntervalSince1970: 2),
                completedAt: Date(timeIntervalSince1970: 1)
            )
        }
    }

    private func artifactReference(
        path: String,
        role: ArtifactRole,
        byteCount: UInt64
    ) throws -> ArtifactReference {
        try ArtifactReference(
            digest: try ContentDigest(
                algorithm: .sha256,
                hexadecimalValue: String(repeating: "a", count: 64)
            ),
            byteCount: byteCount,
            descriptor: ArtifactDescriptor(
                role: role,
                kind: .waveform,
                format: .json
            )
        )
    }
}

private struct FixedSimulationBackend: CoreSpiceSimulationBackend {
    let execution: CoreSpiceSimulationExecution

    func execute(
        _ request: CoreSpiceSimulationRequest
    ) async throws -> CoreSpiceSimulationExecution {
        execution
    }
}

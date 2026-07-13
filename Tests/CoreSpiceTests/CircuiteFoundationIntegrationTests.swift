import CoreSpice
import Foundation
import Testing

@Suite
struct CircuiteFoundationIntegrationTests {
    @Test
    func adapterProducesFoundationEvidenceWithExactExecutionMetadata() async throws {
        let input = try artifactReference(path: "inputs/circuit.spice", byteCount: 12)
        let output = try artifactReference(path: "outputs/waveform.raw", byteCount: 24)
        let startedAt = Date(timeIntervalSince1970: 100)
        let completedAt = Date(timeIntervalSince1970: 101)
        let execution = try CoreSpiceSimulationExecution(
            artifacts: [output],
            diagnostics: [],
            startedAt: startedAt,
            completedAt: completedAt
        )
        let producer = try ProducerIdentity(
            kind: .engine,
            identifier: "CoreSpice",
            version: "1.0.0"
        )
        let executor = FixedSimulationExecutor(execution: execution)
        let engine = CoreSpiceSimulationEngineAdapter(
            executor: executor,
            producer: producer
        )
        let request = CoreSpiceSimulationRequest(
            inputs: [input],
            randomSeed: 7
        )

        let result = try await engine.execute(request)

        #expect(result.artifacts == [output])
        #expect(result.evidence.artifacts == [output])
        #expect(result.evidence.provenance.inputs == [input])
        #expect(result.evidence.provenance.randomSeed == 7)
        #expect(result.evidence.provenance.startedAt == startedAt)
        #expect(result.evidence.provenance.completedAt == completedAt)
    }

    @Test
    func executionRejectsAnImpossibleTimeline() {
        #expect(throws: CoreSpiceSimulationExecutionError.self) {
            try CoreSpiceSimulationExecution(
                artifacts: [],
                startedAt: Date(timeIntervalSince1970: 2),
                completedAt: Date(timeIntervalSince1970: 1)
            )
        }
    }

    private func artifactReference(
        path: String,
        byteCount: UInt64
    ) throws -> ArtifactReference {
        ArtifactReference(
            id: ArtifactID(rawValue: try #require(UUID(uuidString: "AF43165C-EC65-449D-868E-D26EB9C25A3F"))),
            locator: ArtifactLocator(
                location: try ArtifactLocation(workspaceRelativePath: path),
                kind: .waveform,
                format: .json
            ),
            digest: try ContentDigest(
                algorithm: .sha256,
                hexadecimalValue: String(repeating: "a", count: 64)
            ),
            byteCount: byteCount
        )
    }
}

private struct FixedSimulationExecutor: CoreSpiceSimulationExecuting {
    let execution: CoreSpiceSimulationExecution

    func execute(
        _ request: CoreSpiceSimulationRequest
    ) async throws -> CoreSpiceSimulationExecution {
        execution
    }
}

import CoreSpiceOSDITestSupport
import Foundation
import Darwin
import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFileSystem
import CircuiteFoundationFoundation
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceOSDI
import Testing

@Suite(.timeLimit(.minutes(1)))
struct OSDIProtocolStateTests {
    @Test func candidateWritesNeverCommitPreviousHistoryAcrossNewtonAndPhysicalRestamps() async throws {
        // This unchanged S2 ABI fixture qualifies state transport, not physical model equations.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dependency = root.appendingPathComponent(".build/checkouts/swift-osdi")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("corespice-osdi-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Protocol artifact cleanup failed") } }
        let output = directory.appendingPathComponent("state.dylib")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        process.arguments = ["-dynamiclib", "-O2", "-DPROTOCOL_MODE=0",
            "-I", dependency.appendingPathComponent("Sources/COSDI/ABI").path,
            dependency.appendingPathComponent("Tests/OSDIEvaluationTests/Fixtures/protocol.c").path,
            "-o", output.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        do {
            while process.isRunning {
                guard ContinuousClock.now < deadline else { throw OSDIDCManifest.Failure.oracleFailure("protocol compilation timeout") }
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; throw error }
        guard process.terminationStatus == 0 else { throw OSDIDCManifest.Failure.oracleFailure("protocol compilation failed") }
        let reference = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
            ArtifactLocator(location: ArtifactLocation(workspaceRelativePath: "state.dylib"), role: .input, kind: .model, format: .raw), relativeTo: directory)
        let fixture = try OSDIAdapterFixture(library: .init(id: "protocol-state", path: output.path,
            sha256: reference.digest.hexadecimalValue, descriptorIndex: 0, descriptorName: "protocol_transport"))
        do {
            var prepared = try await fixture.prepare([fixture.instance("Nstate", nodes: [Node(id: 1)], previousState: [3, 7])])
            do {
                let topology = CircuitTopology(ir: prepared.circuit)
                var context = fixture.context(topology)
                guard let owner = try prepared.takeDevice(at: 0) else { throw OSDIAdapterFixture.FixtureFailure.missingOwner }
                let device = try owner.bind(context: &context)
                let physical = try #require(device as? any OSDIPhysicalResidualContributing)
                for x in [2.0, 2.0, 4.0, 2.0] {
                    let state = SolutionState(variables: [x], variableMap: topology.variableMap)
                    var matrix = 0.0, rhs = 0.0, residual = 0.0
                    var stamp = MatrixStamper(variableMap: topology.variableMap,
                        stampMatrix: { _, _, _ in }, stampRHS: { _, value in rhs += value }, stampValue: { _, value in matrix += value })
                    try device.stampDC(into: &stamp, state: state)
                    try physical.accumulatePhysicalResidual(state: state) { _, value in residual += value }
                    #expect(matrix == 1)
                    #expect(rhs == -3)
                    #expect(residual == x + 3)
                }
                try prepared.close()
            } catch { do { try prepared.close() } catch { Issue.record("Prepared cleanup failed") }; throw error }
        } catch { do { try await fixture.close() } catch { Issue.record("Fixture cleanup failed") }; throw error }
        try await fixture.close()
    }
}

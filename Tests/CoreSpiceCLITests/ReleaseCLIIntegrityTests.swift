import CoreSpiceIO
import CoreSpiceLowering
import CoreSpiceEvent
import CircuiteFoundation
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite("Release CLI invocation integrity", .timeLimit(.minutes(1)))
struct ReleaseCLIIntegrityTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("release-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func cleanup(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Cleanup failed: \(error)") }
    }
    private func batch(_ arguments: [String]) async throws -> CoreSpiceCLIBatchRunRecord {
        var session = try Session(policy: .developerV1())
        return try await CLI(arguments: arguments).executeBatch(options: .init(arguments: arguments), session: &session)
    }
    private let deck = "Integrity\nV1 in 0 1\nR1 in 0 1k\n.op\n.end\n"

    @Test func batchRejectsSourceAndOutputAliasesWithoutMutation() async throws {
        let root = try directory(); defer { cleanup(root) }
        let source = root.appendingPathComponent("deck.cir")
        try deck.write(to: source, atomically: true, encoding: .utf8)
        let hard = root.appendingPathComponent("hard.cir")
        let symbolic = root.appendingPathComponent("symbolic.cir")
        try FileManager.default.linkItem(at: source, to: hard)
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: source)
        for target in [source, hard, symbolic] {
            do {
                _ = try await batch(["-b", source.path, "--coverage-json", target.path])
                Issue.record("Source alias accepted")
            } catch { }
            #expect(try String(contentsOf: source, encoding: .utf8) == deck)
            #expect(try String(contentsOf: target, encoding: .utf8) == deck)
        }
        let output = root.appendingPathComponent("output")
        do {
            _ = try await batch(["-b", source.path, "-r", output.path, "--csv", output.path])
            Issue.record("Duplicate output accepted")
        } catch { }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func preparedRejectsSourceAliasesWithoutMutation() async throws {
        let root = try directory(); defer { cleanup(root) }
        let source = root.appendingPathComponent("deck.cir")
        try deck.write(to: source, atomically: true, encoding: .utf8)
        do {
            _ = try await CoreSpicePreparedCommand(arguments: [source.path, "--csv", source.path]).execute()
            Issue.record("Prepared source alias accepted")
        } catch { }
        #expect(try String(contentsOf: source, encoding: .utf8) == deck)
    }

    @Test func finalArtifactsDescribeEveryPublishedByte() async throws {
        let root = try directory(); defer { cleanup(root) }
        let source = root.appendingPathComponent("deck.cir")
        try deck.write(to: source, atomically: true, encoding: .utf8)
        let csv = root.appendingPathComponent("out.csv")
        let raw = root.appendingPathComponent("out.raw")
        let coverage = root.appendingPathComponent("coverage.json")
        let record = try await batch(["-b", source.path, "--csv", csv.path, "-r", raw.path, "--coverage-json", coverage.path])
        let referencer = try CoreSpiceCLIArtifactReferencer()
        let expected = try [referencer.output(path: csv.path, kind: .waveform, format: .csv),
                            referencer.output(path: raw.path, kind: .waveform, format: .raw),
                            referencer.output(path: coverage.path, kind: .report, format: .json)]
        #expect(Set(record.outputArtifacts) == Set(expected))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".corespice-output-") })
    }

    @Test func measureUsesCapturedBytesAfterPathReplacement() async throws {
        let root = try directory(); defer { cleanup(root) }
        let source = root.appendingPathComponent("wave.csv")
        try "time [s],V(out) [V]\n0,1\n1,2\n".write(to: source, atomically: true, encoding: .utf8)
        let expected = try CoreSpiceCLIArtifactReferencer().input(path: source.path, kind: .waveform, format: .csv)
        let options = try CoreSpiceMeasureOptions(arguments: ["--waveform", source.path, "--measure", "tran peak MAX V(out)"])
        let record = try await CoreSpiceMeasureCommand(options: options).execute(afterCapture: {
            try "time [s],V(out) [V]\n0,9\n1,10\n".write(to: source, atomically: true, encoding: .utf8)
        })
        #expect(record.measurements.first?.value == 2)
        #expect(record.inputArtifact == expected)
    }

    @Test func sourceAnalysesAndMeasurementsAllComplete() async throws {
        let root = try directory(); defer { cleanup(root) }
        let source = root.appendingPathComponent("deck.cir")
        try "Multi\nV1 in 0 1\nR1 in 0 1k\n.op\n.tran 1u 2u\n.meas tran peak MAX V(in)\n.end\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let record = try await batch(["-b", source.path])
        #expect(record.analyses == ["op", "tran"])
        #expect(record.schemaVersion.major == 6)
        #expect(record.analysisCompletions?.map(\.analysis) == ["op", "tran"])
        #expect(try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: JSONEncoder().encode(record)) == record)
        #expect(record.measurements.first?.name == "peak")
        #expect(record.measurements.first?.value == 1)
    }

    @Test func transientFourierAndMixedMonteCarloAreAllRequestedWork() async throws {
        let root = try directory(); defer { cleanup(root) }
        let source = root.appendingPathComponent("deck.cir")
        try "Fourier\nV1 in 0 sin(0 1 1k)\nR1 in 0 1k\n.tran 10u 2m\n.four 1k V(in)\n.end\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let fourier = try await batch(["-b", source.path])
        #expect(fourier.analyses == ["tran", "four"])
        #expect(fourier.analysisCompletions?.count == 2)
        try "Mixed\nV1 in 0 1\nR1 in 0 1k\n.op\n.mc 2 dc V1 0 1 1\n.meas dc peak MAX V(in)\n.end\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let mixed = try await batch(["-b", source.path, "--seed", "42"])
        #expect(mixed.analyses == ["op", "mc(dc)"])
        #expect(mixed.waveform?.runs == 2)
        #expect(mixed.measurements.first?.value == 1)
        #expect(try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: JSONEncoder().encode(mixed)) == mixed)
    }

    @Test func batchDecoderRejectsUnsupportedVersionAndUnknownCompletion() async throws {
        let root = try directory(); defer { cleanup(root) }
        let source = root.appendingPathComponent("deck.cir")
        try deck.write(to: source, atomically: true, encoding: .utf8)
        let record = try await batch(["-b", source.path])
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        for version in [["major": 99, "minor": 0, "patch": 0], ["major": 0, "minor": 0, "patch": 0],
                        ["major": 3, "minor": 1, "patch": 0]] {
            var edited = object; edited["schemaVersion"] = version
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: JSONSerialization.data(withJSONObject: edited))
            }
        }
        #expect(throws: (any Error).self) {
            try CoreSpiceCLIAnalysisCompletion(analysis: "unknown", waveform: .init(variables: ["V(in)"], points: 1),
                nativeDCResult: nil, osdiExecution: nil, osdiModels: nil, osdiVariables: nil)
        }
    }

    @Test func unfulfilledMeasurementRefusesAllOutputs() async throws {
        let root = try directory(); defer { cleanup(root) }
        let source = root.appendingPathComponent("deck.cir")
        let output = root.appendingPathComponent("out.csv")
        try "Missing\nV1 in 0 1\nR1 in 0 1k\n.op\n.meas tran peak MAX V(in)\n.end\n"
            .write(to: source, atomically: true, encoding: .utf8)
        do {
            _ = try await batch(["-b", source.path, "--csv", output.path])
            Issue.record("Missing analysis measurement accepted")
        } catch { }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func missingCrossingRefusesOutputAfterEveryPhase() async throws {
        let root = try directory(); defer { cleanup(root) }
        let source = root.appendingPathComponent("deck.cir")
        let output = root.appendingPathComponent("out.csv")
        try "No crossing\nV1 in 0 1\nR1 in 0 1k\n.op\n.tran 1u 2u\n.meas tran crossing WHEN V(in)=2 RISE=1\n.end\n"
            .write(to: source, atomically: true, encoding: .utf8)
        do {
            _ = try await batch(["-b", source.path, "--csv", output.path])
            Issue.record("Missing crossing accepted")
        } catch { }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func cancellationStopsMonteCarloWithoutCompletedEnsemble() async throws {
        var session = try Session(policy: .developerV1())
        try await session.loadNetlist(source: "Cancelled\nV1 in 0 1\nR1 in 0 1k\n.mc 2 dc V1 0 1 1\n.end\n", fileName: nil)
        let spec = try #require(session.monteCarloSpec)
        let cancellation = CancellationToken()
        cancellation.cancel()
        do {
            _ = try await session.runMonteCarlo(spec: spec, inner: spec.analysis, cancellation: cancellation)
            Issue.record("Cancelled Monte Carlo completed")
        } catch { }
        #expect(session.lastParametric == nil)
    }

    @Test func retainedMonteCarloSamplesShareOneFiniteQuotaAndRelease() async throws {
        let policy = try CoreSpiceCLIExecutionPolicy.developerV1()
        let resources = try policy.resources()
        let frontend = try NetlistLowering.resourceEnvelope(limits: policy.resolutionLimits).maximumRetainedBytes
        var session = Session(policy: policy)
        try await session.loadNetlist(source: "Quota\nV1 in 0 1\nR1 in 0 1k\n.mc 2 dc V1 0 1 1\n.end\n", fileName: nil)
        session.phaseCollector = try CoreSpiceCLIPhaseCollector()
        let spec = try #require(session.monteCarloSpec)
        // Permit two concurrent frontend resolutions, then the retained first sample
        // must consume the capacity needed by the next fresh resolution.
        var held: SPICESourceStorageReservation? = try resources.reserveStorage(kind: .liveOwnedBytes,
            byteCount: 128 * 1024 * 1024 - 2 * frontend)
        do {
            _ = try await session.runMonteCarlo(spec: spec, inner: spec.analysis, seedOverride: 42)
            Issue.record("Cumulative retained sample capacity was reset")
        } catch { }
        #expect(session.phaseCollector?.phases.count == 2)
        #expect(session.phaseCollector?.phases.allSatisfy { $0.id.hasPrefix("mc-seed:42:") } == true)
        #expect(session.lastParametric == nil)
        session = Session(policy: policy)
        withExtendedLifetime(held) { }
        held = nil
        let released = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: 128 * 1024 * 1024)
        withExtendedLifetime(released) { }
    }

    @Test func developerLedgerDoesNotResetBetweenResolutionSessions() throws {
        let policy = try CoreSpiceCLIExecutionPolicy.developerV1()
        let first = try policy.resources()
        #expect(first === (try policy.resources()))
        var reservation: SPICESourceStorageReservation? = try first.reserveStorage(kind: .liveOwnedBytes, byteCount: 80 * 1024 * 1024)
        do {
            _ = try policy.resources().reserveStorage(kind: .liveOwnedBytes, byteCount: 64 * 1024 * 1024)
            Issue.record("Invocation ledger reset")
        } catch { }
        withExtendedLifetime(reservation) { }
        reservation = nil
        let reused = try policy.resources().reserveStorage(kind: .liveOwnedBytes, byteCount: 128 * 1024 * 1024)
        withExtendedLifetime(reused) { }
    }
}

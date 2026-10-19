import CoreSpiceEvent
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite("Prepared source family persistence", .timeLimit(.minutes(2)))
struct PreparedFamilyPersistenceTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prepared-family-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func cleanup(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("Prepared family cleanup failed: \(error)") }
    }
    private func execute(_ text: String, in root: URL, extra: [String] = []) async throws -> CoreSpiceCLIPreparedRunRecord {
        let deck = root.appendingPathComponent("deck.cir")
        try text.write(to: deck, atomically: true, encoding: .utf8)
        return try await CoreSpicePreparedCommand(arguments: [deck.path] + extra).executeWithRecord().record
    }

    @Test func temperatureAndMonteCarloPersistEveryCaseAndActualValues() async throws {
        let root = try directory(); defer { cleanup(root) }
        let csv = root.appendingPathComponent("family.csv")
        let record = try await execute("""
        Full family
        .temp 0 50
        .param resistance=agauss(1000,100,1)
        V1 in 0 1
        R1 in 0 {resistance}
        .mc 2 dc V1 0 1 1 seed=42
        .meas dc peak MAX V(in)
        .end
        """, in: root, extra: ["--csv", csv.path])
        let runs = try #require(record.cases)
        #expect(record.schemaVersion == 6)
        #expect(runs.count == 4)
        #expect(runs.map(\.selection.seed) == [42, 43, 42, 43])
        #expect(runs.map(\.selection.temperatureCelsius) == [0, 0, 50, 50])
        #expect(runs.map(\.selection.monteCarloIteration) == [0, 1, 0, 1])
        #expect(runs.allSatisfy { $0.measurements.first?.value == 1 })
        #expect(Set(runs.map(\.completion.configurationIdentity)).count == 4)
        #expect(runs.allSatisfy { $0.waveform.coordinates == [0, 1] })
        let data = try JSONEncoder().encode(record)
        let restored = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: data)
        #expect(restored.cases?.count == 4)
        #expect(restored.configurationIdentity == record.configurationIdentity)
        let lines = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n")
        #expect(lines.first?.hasPrefix("case,temperature_celsius,") == true)
        for index in runs.indices { #expect(lines.dropFirst().contains { $0.hasPrefix("\(index),") }) }
    }

    @Test func explicitZeroSeedOverridesSourceSeedAndRetainsOrigin() async throws {
        let root = try directory(); defer { cleanup(root) }
        let source = "Seed\nV1 in 0 1\nR1 in 0 1k\n.mc 2 dc V1 0 1 1 seed=42\n.end\n"
        let record = try await execute(source, in: root, extra: ["--seed", "0"])
        #expect(record.cases?.map(\.selection.seed) == [0, 1])
        #expect(record.cases?.allSatisfy { $0.selection.monteCarloSeedOrigin == "callerOverride" } == true)
        let declared = try await execute(source, in: root)
        #expect(declared.cases?.map(\.selection.seed) == [42, 43])
        #expect(declared.cases?.allSatisfy { $0.selection.monteCarloSeedOrigin == "sourceDirective" } == true)
    }

    @Test func alteredOrMissingFamilyMemberCannotDecode() async throws {
        let root = try directory(); defer { cleanup(root) }
        let record = try await execute("Temp\n.temp 0 50\nV1 in 0 1\nR1 in 0 1k\n.op\n.end\n", in: root)
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var cases = try #require(object["cases"] as? [[String: Any]])
        cases.removeLast(); object["cases"] = cases
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: JSONSerialization.data(withJSONObject: object))
        }
        object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        cases = try #require(object["cases"] as? [[String: Any]])
        cases.swapAt(0, 1); object["cases"] = cases
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func preparedMOSMonteCarloKeepsActualResolvedSeedGeometry() async throws {
        let root = try directory(); defer { cleanup(root) }
        let record = try await execute("""
        MOS family
        .param length=agauss(1u,.1u,1)
        .model n nmos level=1 vto=.5 kp=1m
        VD d 0 1
        VG g 0 1
        M1 d g 0 0 n l={length} w=2u
        .mc 2 dc VG .7 1 .3 seed=42
        .end
        """, in: root)
        let runs = try #require(record.cases)
        #expect(runs.count == 2)
        let first = try #require(runs[0].mosModels.first?.instanceParameters["l"])
        let second = try #require(runs[1].mosModels.first?.instanceParameters["l"])
        #expect(first != second)
        #expect(runs.allSatisfy { $0.mosModels.allSatisfy { $0.coldSetupCount == 1 } })
    }

    @Test func preparedSensitivitySavesFreshChildSourceBindings() async throws {
        let root = try directory(); defer { cleanup(root) }
        let record = try await execute("Sensitivity\nV1 in 0 1\nR1 in out 1k\nR2 out 0 2k\n.sens V(out)\n.end\n", in: root)
        let run = try #require(record.cases?.first)
        #expect(run.completion.schemaVersion == 7)
        #expect(run.waveform.analysis.rawValue == "sens")
        #expect(!run.sourceReexecutions.isEmpty)
        #expect(run.sourceReexecutions.allSatisfy { !$0.sourceOverrides.isEmpty && $0.sourceInputIdentity == record.sourceInputIdentity })
        #expect(Set(run.sourceReexecutions.map(\.configurationIdentity)).count == run.sourceReexecutions.count)
        var invalid = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(run.completion)) as? [String: Any])
        var saved = try #require(invalid["savedWaveform"] as? [String: Any])
        var real = try #require(saved["real"] as? [Double]); real[0] += 1
        saved["real"] = real; invalid["savedWaveform"] = saved
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: JSONSerialization.data(withJSONObject: invalid)) }
        _ = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: JSONEncoder().encode(record))
    }

    @Test func familySharesNumericalWorkCeilingAcrossCases() async throws {
        let root = try directory(); defer { cleanup(root) }
        func source(iterations: Int, attempts: Int) -> String {
            "Quota\n.options tranmaxaccepted=100 tranmaxattempts=\(attempts) tranmaxiterations=10000 tranmaxscalars=1000 tranmaxdimension=16 tranmaxwork=10000000 tranmaxbreakpoints=100\nV1 in 0 1\nR1 in 0 1k\n.mc \(iterations) dc V1 1 1 1\n.end\n"
        }
        let calibration = try await execute(source(iterations: 1, attempts: 100), in: root)
        let attempts = try #require(calibration.numericalUsage?.solveAttempts)
        #expect(attempts > 0)
        _ = try await execute(source(iterations: 1, attempts: attempts), in: root)
        let csv = root.appendingPathComponent("quota.csv")
        do {
            _ = try await execute(source(iterations: 2, attempts: attempts), in: root, extra: ["--csv", csv.path])
            Issue.record("Numerical invocation ceiling reset for the second case")
        } catch { }
        #expect(!FileManager.default.fileExists(atPath: csv.path))
    }

    @Test func failedCaseDoesNotPublishAnyFamilyCSV() async throws {
        let root = try directory(); defer { cleanup(root) }
        let csv = root.appendingPathComponent("family.csv")
        do {
            _ = try await execute("Failure\n.temp 0 50\nV1 in 0 1\nR1 in 0 1k\n.tran 1u 2u\n.meas tran missing WHEN V(in)=2 RISE=1\n.end\n", in: root, extra: ["--csv", csv.path])
            Issue.record("Unfulfilled family measurement completed")
        } catch { }
        #expect(!FileManager.default.fileExists(atPath: csv.path))
    }
}

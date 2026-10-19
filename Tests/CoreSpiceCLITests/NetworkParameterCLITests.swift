@testable import CoreSpiceCLICore
import CoreSpiceIO
import CoreSpiceAnalysis
import Foundation
import Testing

@Suite("Fixed-bias RF CLI composition", .timeLimit(.minutes(1)))
struct NetworkParameterCLITests {
    private let flags = ["--analysis-index", "0", "--network-port", "v1", "50", "--network-port", "v2", "75", "--network-residual-tolerance", "1e-10"]
    private func fixture(temperatureFamily: Bool = false) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("network-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let path = directory.appendingPathComponent("ports.cir")
        try ("""
        Coupled network
        V1 a 0 dc 1 ac 23
        V2 b 0 dc 2 ac 71
        R1 a 0 100
        R2 b 0 200
        R3 a b 400
        .ac lin 2 100 200
        """ + (temperatureFamily ? "\n.temp 27 77" : "") + "\n.end\n").write(to: path, atomically: true, encoding: .utf8)
        return (directory, path)
    }
    private func decoder() throws -> JSONDecoder {
        let policy = try CoreSpiceCLIExecutionPolicy.developerV1()
        return try CoreSpiceCLIJSON.networkDecoder(numericalResources: AnalysisExecutionResources(limits: policy.numericalLimits),
            sourceResources: policy.resources())
    }
    private func cleanup(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("RF fixture cleanup failed: \(error)") }
    }

    @Test func preparedExactMatricesBiasAndAvailabilityColdReloadAlongsideTouchstoneAndCSV() async throws {
        let (directory, path) = try fixture(); defer { cleanup(directory) }
        let csv = directory.appendingPathComponent("network.csv")
        let ts = directory.appendingPathComponent("network.s2p")
        let completed = try await CoreSpicePreparedCommand(arguments: [path.path] + flags + ["--json", "--csv", csv.path, "--touchstone", ts.path]).executeWithRecord()
        let encoded = try #require(completed.serializedPrecisionJSON)
        let saved = try decoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(encoded.utf8))
        let cases = try #require(saved.cases); try #require(cases.count == 1)
        let actual = try #require(completed.output.networkResult)
        let rf = try #require(cases[0].completion.network)
        #expect(saved.schemaVersion == 6 && cases[0].completion.schemaVersion == 9)
        #expect(rf.ports.map(\.source) == ["v1", "v2"])
        #expect(rf.operatingPoint.analysis == "op")
        for (index, point) in actual.points.enumerated() {
            #expect(rf.points[index].y.map(\.real) == point.y.values.map { $0.real.bitPattern })
            #expect(rf.points[index].y.map(\.imaginary) == point.y.values.map { $0.imag.bitPattern })
            #expect(rf.points[index].s.map(\.real) == point.s.values.map { $0.real.bitPattern })
            guard case .defined(let z) = point.z else { Issue.record("Unexpected singular fixture"); continue }
            #expect(rf.points[index].z?.map(\.real) == z.values.map { $0.real.bitPattern })
        }
        let interchange = try TouchstoneDecoder().decode(Data(contentsOf: ts))
        #expect(interchange.referenceResistances == [50, 75])
        #expect(interchange.points.count == actual.points.count)
        for (index, point) in interchange.points.enumerated() {
            #expect(point.matrix.values.map { $0.real.bitPattern } == actual.points[index].s.values.map { $0.real.bitPattern })
            #expect(point.matrix.values.map { $0.imag.bitPattern } == actual.points[index].s.values.map { $0.imag.bitPattern })
        }
        let rows = try String(contentsOf: csv, encoding: .utf8).split(separator: "\n")
        let expectedRowCount: Int = 1 + 2 * 3 * 4
        #expect(rows.count == expectedRowCount)
        #expect(rows[0].contains("availability"))
        try rf.validateWaveform(cases[0].waveform)
    }

    @Test func requiredNetworkRecordPortReferenceMatrixAndZAvailabilityCannotBeTampered() async throws {
        let (directory, path) = try fixture(); defer { cleanup(directory) }
        let completed = try await CoreSpicePreparedCommand(arguments: [path.path] + flags + ["--json"]).executeWithRecord()
        let leaf = try #require(completed.record.cases?.first?.completion)
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(leaf)) as? [String: Any])
        for mode in 0..<4 {
            var object = original
            if mode == 0 { object.removeValue(forKey: "network") }
            else {
                var network = try #require(object["network"] as? [String: Any])
                if mode == 1 {
                    var ports = try #require(network["ports"] as? [[String: Any]])
                    ports[0]["referenceImpedanceBits"] = Double(100).bitPattern; network["ports"] = ports
                } else {
                    var points = try #require(network["points"] as? [[String: Any]])
                    if mode == 2 { points[0].removeValue(forKey: "z"); points[0]["zUnavailableReason"] = "singularAdmittance" }
                    else {
                        var s = try #require(points[0]["s"] as? [[String: Any]])
                        s[0]["real"] = Double(0.25).bitPattern; points[0]["s"] = s
                    }
                    network["points"] = points
                }
                object["network"] = network
            }
            let changed = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try decoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: changed) }
        }
    }

    @Test func savedStabilityBitsAndAvailabilityReachOneAdmittedMathematicalCheck() async throws {
        let (directory, path) = try fixture(); defer { cleanup(directory) }
        let completed = try await CoreSpicePreparedCommand(arguments: [path.path] + flags + ["--json"]).executeWithRecord()
        let leaf = try #require(completed.record.cases?.first?.completion)
        let encoded = try JSONEncoder().encode(leaf)
        let restored = try decoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: encoded)
        #expect(restored.network?.points[0].stability == leaf.network?.points[0].stability)
        let original = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for mode in ["scattering", "metric", "availability", "malformed"] {
            var object = original
            var network = try #require(object["network"] as? [String: Any])
            var points = try #require(network["points"] as? [[String: Any]])
            if mode == "scattering" {
                var scattering = try #require(points[0]["s"] as? [[String: Any]])
                let old = try #require(scattering[0]["real"] as? NSNumber)
                scattering[0]["real"] = Double(bitPattern: old.uint64Value).nextUp.bitPattern
                points[0]["s"] = scattering
            } else {
                var stability = try #require(points[0]["stability"] as? [String: Any])
                var metric = try #require(stability["mu"] as? [String: Any])
                let old = try #require(metric["valueBits"] as? NSNumber)
                if mode == "metric" {
                    metric["valueBits"] = Double(bitPattern: old.uint64Value).nextUp.bitPattern
                } else {
                    if mode == "availability" { metric.removeValue(forKey: "valueBits") }
                    metric["unavailableReason"] = "zeroDenominator"
                }
                stability["mu"] = metric; points[0]["stability"] = stability
            }
            network["points"] = points; object["network"] = network
            let changed = try JSONSerialization.data(withJSONObject: object)
            do {
                _ = try decoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: changed)
                Issue.record("Modified saved network mathematics published a result")
            } catch NetworkParameterError.inconsistentSavedPoint {
                #expect(mode != "malformed")
            } catch CoreSpiceCLIOSDIError.incompleteReceipt {
                #expect(mode == "malformed")
            }
        }
    }

    @Test func unilateralUndefinedStabilityReasonSurvivesColdReload() async throws {
        let (directory, path) = try fixture(); defer { cleanup(directory) }
        let source = try String(contentsOf: path, encoding: .utf8)
        let unilateral = source.replacingOccurrences(of: "R3 a b 400", with: "G1 b 0 a 0 0.01")
        try unilateral.write(to: path, atomically: true, encoding: .utf8)
        let completed = try await CoreSpicePreparedCommand(arguments: [path.path] + flags + ["--json"]).executeWithRecord()
        let leaf = try #require(completed.record.cases?.first?.completion)
        let restored = try decoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: JSONEncoder().encode(leaf))
        let original = try #require(leaf.network?.points[0].stability)
        let saved = try #require(restored.network?.points[0].stability)
        #expect(original.rollettK.valueBits == nil)
        #expect(original.rollettK.unavailableReason == "zeroDenominator")
        #expect(original.satisfiesRollettInequalities == nil)
        #expect(saved == original)
    }

    @Test func familyPublishesEveryMemberAndOneTouchstonePathRefusesBeforePublication() async throws {
        let (directory, path) = try fixture(temperatureFamily: true); defer { cleanup(directory) }
        let ts = directory.appendingPathComponent("one.s2p")
        do {
            _ = try await CoreSpicePreparedCommand(arguments: [path.path] + flags + ["--touchstone", ts.path]).executeWithRecord()
            Issue.record("Multiple cases were collapsed into one Touchstone file")
        } catch { #expect(!FileManager.default.fileExists(atPath: ts.path)) }
        let output = directory.appendingPathComponent("family")
        let completed = try await CoreSpicePreparedCommand(arguments: [path.path] + flags + ["--network-output-directory", output.path, "--json"]).executeWithRecord()
        #expect(completed.record.expectedCaseCount == 2)
        let members = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        #expect(members == ["case-0.json", "case-0.s2p", "case-1.json", "case-1.s2p", "family.json", "manifest.json", "network.csv"])
        let cold = try decoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(contentsOf: output.appendingPathComponent("family.json")))
        #expect(cold.cases?.map(\.selection.temperatureCelsius) == [27, 77])
        for index in 0..<2 {
            let leaf = try decoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(contentsOf: output.appendingPathComponent("case-\(index).json")))
            #expect(leaf.configurationIdentity == cold.cases?[index].completion.configurationIdentity)
        }
    }

    @Test func ordinaryBatchUsesCanonicalNetworkSchemaAndPreservesOtherACDirective() async throws {
        let (directory, path) = try fixture(); defer { cleanup(directory) }
        var text = try String(contentsOf: path, encoding: .utf8)
        text = text.replacingOccurrences(of: ".end", with: ".ac lin 1 400 400\n.end")
        try text.write(to: path, atomically: true, encoding: .utf8)
        let options = try CoreSpiceBatchOptions(arguments: ["-b", path.path] + flags + ["--json"])
        var session = try Session(policy: .developerV1())
        let batch = try await CLI(arguments: []).executeBatch(options: options, session: &session)
        #expect(batch.schemaVersion.major == 8)
        #expect(batch.analyses == ["network", "ac"])
        let restored = try decoder().decode(CoreSpiceCLIBatchRunRecord.self, from: JSONEncoder().encode(batch))
        #expect(restored.analysisCompletions?.first?.preparedCompletionJSON == batch.analysisCompletions?.first?.preparedCompletionJSON)
    }

    @Test func sourceAliasRefusesWithoutChangingAnyBytesOrStaging() async throws {
        let (directory, path) = try fixture(); defer { cleanup(directory) }
        let before = try Data(contentsOf: path)
        do {
            _ = try await CoreSpicePreparedCommand(arguments: [path.path] + flags + ["--touchstone", path.path]).executeWithRecord()
            Issue.record("Network output aliased its source")
        } catch {
            #expect(try Data(contentsOf: path) == before)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["ports.cir"])
        }
    }
    @Test func touchstoneHeaderTokensFitSingleOutputAndEvery128PointFamilyMember() async throws {
        let (directory, path) = try fixture(); defer { cleanup(directory) }
        var text = try String(contentsOf: path, encoding: .utf8)
        text = text.replacingOccurrences(of: ".ac lin 2 100 200", with: ".ac lin 128 100 200")
        try text.write(to: path, atomically: true, encoding: .utf8)
        let single = directory.appendingPathComponent("128-points.s2p")
        let completed = try await CoreSpicePreparedCommand(arguments: [path.path] + flags + ["--touchstone", single.path]).executeWithRecord()
        let actual = try #require(completed.output.networkResult)
        let saved = try TouchstoneDecoder().decode(Data(contentsOf: single))
        #expect(saved.points.count == 128)
        for (point, original) in zip(saved.points, actual.points) {
            #expect(point.frequencyHz.bitPattern == original.frequency.bitPattern)
            #expect(point.matrix.values.map { $0.real.bitPattern } == original.s.values.map { $0.real.bitPattern })
            #expect(point.matrix.values.map { $0.imag.bitPattern } == original.s.values.map { $0.imag.bitPattern })
        }
        text = text.replacingOccurrences(of: ".end", with: ".temp 27 77\n.end")
        try text.write(to: path, atomically: true, encoding: .utf8)
        let familyDirectory = directory.appendingPathComponent("128-point-family")
        let family = try await CoreSpicePreparedCommand(arguments: [path.path] + flags + ["--network-output-directory", familyDirectory.path]).executeWithRecord()
        let members = try #require(family.record.cases)
        try #require(members.count == 2)
        for member in members {
            let network = try #require(member.completion.network)
            let pointFile = familyDirectory.appendingPathComponent("case-\(member.index).s2p")
            let pointData = try TouchstoneDecoder().decode(Data(contentsOf: pointFile))
            #expect(pointData.points.count == 128)
            for (point, canonical) in zip(pointData.points, network.points) {
                #expect(point.frequencyHz.bitPattern == canonical.frequencyBits)
                #expect(point.matrix.values.map { $0.real.bitPattern } == canonical.s.map(\.real))
                #expect(point.matrix.values.map { $0.imag.bitPattern } == canonical.s.map(\.imaginary))
            }
        }
    }

}

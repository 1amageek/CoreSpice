import CircuiteFoundation
import Foundation
import Testing
import ToolQualification
import CoreSpiceEvent
@testable import CoreSpiceCLICore

@Suite("Original source sensitivity cases", .timeLimit(.minutes(2)))
struct SensitivityCasePublicationTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sensitivity-case-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func cleanup(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Sensitivity fixture cleanup failed: \(error)") }
    }
    private func run(_ source: String, root: URL) async throws -> (ToolQualificationCaseExecution, CoreSpiceCLISensitivityEvidence) {
        let deck = root.appendingPathComponent("deck.cir"), output = root.appendingPathComponent("case")
        try source.write(to: deck, atomically: true, encoding: .utf8)
        let args = ["-b", deck.path, "--case-output", output.path, "--case-id", "source-sensitivity", "--json"]
        var session = try Session(policy: .developerV1())
        let batch = try await CLI(arguments: args).executeBatch(options: .init(arguments: args), session: &session)
        #expect(batch.schemaVersion.major == 7)
        let encoded = try JSONEncoder().encode(batch)
        #expect(try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: encoded) == batch)
        var invalid = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var completions = try #require(invalid["analysisCompletions"] as? [[String: Any]])
        completions[0]["preparedCompletionJSON"] = "{}"; invalid["analysisCompletions"] = completions
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: JSONSerialization.data(withJSONObject: invalid)) }
        let execution = try ToolQualificationCaseExecution.decodeCanonical(from: Data(contentsOf: output.appendingPathComponent("execution.json")))
        let evidence = try JSONDecoder().decode(CoreSpiceCLISensitivityEvidence.self, from: Data(contentsOf: output.appendingPathComponent("sensitivity-0.json")))
        let domain = try JSONDecoder().decode([String: CoreSpiceCLIMetricSemantics].self, from: Data(contentsOf: output.appendingPathComponent("metric-domain.json")))
        #expect(Set(domain.keys) == Set(execution.observedMetrics.keys))
        #expect(domain.values.allSatisfy { $0.derivationArtifact != nil && $0.sourceCompletionArtifact != nil })
        let artifact = try CoreSpiceCLIArtifactReferencer().output(path: output.appendingPathComponent("sensitivity-0.json").path, kind: .report, format: .json)
        #expect(domain.values.allSatisfy { $0.derivationArtifact == artifact })
        for (metric, contributors) in execution.metricPhaseIDs where metric.contains(":derived:") {
            #expect(contributors.count == 2)
            #expect(contributors.first?.contains("baseline") == true)
            #expect(contributors.last?.contains("child") == true)
        }
        return (execution, evidence)
    }

    @Test func resistorDCUsesActualBaselineChildAndExactIncrement() async throws {
        let root = try directory(); defer { cleanup(root) }
        let (execution, evidence) = try await run("Sense\nV1 in 0 1\nR1 in out 1k\nR2 out 0 2k\n.sens V(out)\n.end\n", root: root)
        #expect(evidence.analysis == "sens-dc")
        #expect(abs(evidence.baseline[0].real - 2.0 / 3.0) < 1e-8)
        let child = try #require(evidence.children.first { $0.instance.lowercased() == "r1" && $0.parameter == "instance.r" })
        let replacement = Double(bitPattern: child.replacementBits)
        #expect(abs(child.observations[0].real - 2000 / (2000 + replacement)) < 1e-8)
        #expect(child.absolute[0].real < 0)
        #expect(child.source.physicalAnalysis == "op")
        #expect(execution.phaseIDs.count == evidence.children.count + 2)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
        var children = try #require(object["children"] as? [[String: Any]])
        children[0]["replacementBits"] = Double(999).bitPattern; object["children"] = children
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CoreSpiceCLISensitivityEvidence.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func acAndMOSCasesPreserveFreshModelsAndPhysicalObservations() async throws {
        for mos in [false, true] {
            let root = try directory(); defer { cleanup(root) }
            let source = mos ? "MOS\n.model n nmos level=1 vto=.5 kp=1m\nVG g 0 1\nVS supply 0 dc 1 ac 1\nR1 supply out 1k\nM1 out g 0 0 n l=1u w=2u\n.sens V(out) ac lin 2 100 200\n.end\n"
                : "RC\nV1 in 0 dc 1 ac 1\nR1 in out 1k\nC1 out 0 1u\n.sens V(out) ac lin 2 100 200\n.end\n"
            let (_, evidence) = try await run(source, root: root)
            #expect(evidence.analysis == "sens-ac" && evidence.frequencies == [100, 200])
            #expect(evidence.children.allSatisfy { $0.observations.count == 2 && $0.source.physicalAnalysis == "ac" })
            if mos {
                let kp = try #require(evidence.children.first { $0.parameter == "model.kp" })
                #expect(kp.source.mosModels.contains { $0.modelParameters["kp"] == Double(bitPattern: kp.replacementBits) })
                #expect(!kp.source.configurationIdentity.isEmpty)
                let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("case"), includingPropertiesForKeys: nil)
                let receipts = try files.filter { $0.lastPathComponent.hasPrefix("model-receipt-") }.map {
                    try ToolQualificationModelExecutionReceipt.decodeCanonical(from: Data(contentsOf: $0))
                }
                #expect(receipts.contains { $0.resolvedParameters["kp"] == Double(bitPattern: kp.replacementBits) })
            }
        }
    }

    @Test func zeroBaselineKeepsNormalizationUnavailable() async throws {
        let root = try directory(); defer { cleanup(root) }
        let (_, evidence) = try await run("Zero\nV1 out 0 0\nR1 out 0 1k\n.sens V(out)\n.end\n", root: root)
        #expect(evidence.baseline[0].real == 0)
        #expect(evidence.children.allSatisfy { $0.normalized.allSatisfy { $0 == nil } })
    }

    @Test func caseDestinationAliasRefusesBeforeAnyOutputStaging() async throws {
        let root = try directory(); defer { cleanup(root) }
        let deck = root.appendingPathComponent("deck.cir"), csv = root.appendingPathComponent("result.csv")
        let source = "Alias\nV1 out 0 1\nR1 out 0 1k\n.sens V(out)\n.end\n"
        try source.write(to: deck, atomically: true, encoding: .utf8)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let args = ["-b", deck.path, "--case-output", deck.path, "--case-id", "alias", "--csv", csv.path, "--json"]
        var session = try Session(policy: .developerV1())
        do {
            _ = try await CLI(arguments: args).executeBatch(options: .init(arguments: args), session: &session)
            Issue.record("Case source alias completed")
        } catch let error as CoreSpiceCLICaseError {
            guard case .publication = error else { throw error }
        }
        #expect(try String(contentsOf: deck, encoding: .utf8) == source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == before)
    }

    @Test func cancelledSensitivityNeverPublishesCase() async throws {
        let root = try directory(); defer { cleanup(root) }
        let deck = root.appendingPathComponent("deck.cir"), output = root.appendingPathComponent("case")
        try "Cancel\nV1 out 0 1\nR1 out 0 1k\n.sens V(out)\n.end\n".write(to: deck, atomically: true, encoding: .utf8)
        let args = ["-b", deck.path, "--case-output", output.path, "--case-id", "cancelled", "--json"]
        let task = Task {
            try Task.checkCancellation()
            var session = try Session(policy: .developerV1())
            return try await CLI(arguments: args).executeBatch(options: .init(arguments: args), session: &session)
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled sensitivity completed") } catch { }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}

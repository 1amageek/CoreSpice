import CoreSpiceOSDITestSupport
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite("OSDI precision CLI refusals", .timeLimit(.minutes(1)))
struct OSDIPrecisionCLIRefusalTests {
    private static let budgetKeys = [
        "maximumNativeAllocationBytes", "maximumLiveOwnedBytes", "maximumTemporaryBytes",
        "maximumHashedBytes", "maximumEvidenceBytes"
    ]

    @Test(arguments: budgetKeys)
    func everyExecutionBudgetMustBeExplicitAndPositive(_ key: String) async throws {
        for missing in [true, false] {
            try await withFixture { fixture in
                var catalog = fixture.catalogJSON
                var budget = try #require(catalog["executionBudget"] as? [String: Any])
                if missing { budget.removeValue(forKey: key) }
                else { budget[key] = 0 }
                catalog["executionBudget"] = budget
                try write(catalog, to: fixture.catalog)
                try await requireRefusal(fixture, code: "osdi.catalog")
            }
        }
    }

    @Test(arguments: ["missing-budget", "unrepresentable-budget", "schema1-precision"])
    func catalogVersionAndExecutionEnvelopeRefuseInvalidAdmission(_ mutation: String) async throws {
        try await withFixture { fixture in
            var catalog = fixture.catalogJSON
            switch mutation {
            case "missing-budget": catalog.removeValue(forKey: "executionBudget")
            case "unrepresentable-budget":
                var budget = try #require(catalog["executionBudget"] as? [String: Any])
                budget["maximumEvidenceBytes"] = UInt64(Int.max) + 1
                catalog["executionBudget"] = budget
            case "schema1-precision": catalog["schemaVersion"] = 1
            default: throw OSDIDCManifest.Failure.invalidManifest
            }
            try write(catalog, to: fixture.catalog)
            try await requireRefusal(fixture, code: "osdi.catalog")
        }
    }

    @Test(arguments: ["worker", "model"])
    func changedExactArtifactBytesCannotPublishCompletion(_ artifact: String) async throws {
        try await withFixture { fixture in
            let path = artifact == "worker" ? fixture.workerPath : fixture.root.appendingPathComponent("model.osdi")
            let handle = try FileHandle(forWritingTo: path)
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0]))
                try handle.close()
            } catch {
                do { try handle.close() } catch { Issue.record("Corrupted fixture close failed: \(error)") }
                throw error
            }
            try await requireRefusal(fixture, code: "osdi.preparation")
        }
    }

    @Test(arguments: ["semantic-profile", "invalid-options", "out-of-policy-bits"])
    func explicitPrecisionPolicyCannotBeSilentlyReplaced(_ mutation: String) async throws {
        try await withFixture { fixture in
            var catalog = fixture.catalogJSON
            var precision = try #require(catalog["transientPrecision"] as? [String: Any])
            switch mutation {
            case "semantic-profile":
                let original = try #require(precision["semanticProfileSHA256"] as? String)
                precision["semanticProfileSHA256"] = String(repeating: original.first == "0" ? "1" : "0", count: 64)
            case "invalid-options":
                var options = try #require(precision["options"] as? [String: Any])
                options["minimumPrecisionBits"] = 512
                options["maximumPrecisionBits"] = 128
                precision["options"] = options
            case "out-of-policy-bits": precision["precisionBits"] = 0
            default: throw OSDIDCManifest.Failure.invalidManifest
            }
            catalog["transientPrecision"] = precision
            try write(catalog, to: fixture.catalog)
            try await requireRefusal(fixture, code: mutation == "semantic-profile" ? "osdi.preparation" : "osdi.catalog")
        }
    }

    @Test func ordinaryCatalogCannotClaimPairedCSV() async throws {
        try await withFixture { fixture in
            var catalog = fixture.catalogJSON
            catalog["schemaVersion"] = 1
            catalog.removeValue(forKey: "transientPrecision")
            catalog.removeValue(forKey: "executionBudget")
            try write(catalog, to: fixture.catalog)
            try await requireRefusal(fixture, code: "osdi.unsupported-analysis")
        }
    }

    private func withFixture(_ body: (OSDIPrecisionCLIFixture) async throws -> Void) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_PRECISION_MANIFEST"])
        let manifest = try JSONDecoder().decode(OSDIPrecisionManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("osdi-precision-cli-refusal-\(UUID().uuidString)")
        defer {
            do {
                if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            } catch { Issue.record("Precision refusal fixture cleanup failed: \(error)") }
        }
        let fixture = try await OSDIPrecisionCLIFixture.make(modelID: "compound", manifest: manifest, root: root)
        try await body(fixture)
    }

    private func write(_ catalog: [String: Any], to path: URL) throws {
        try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys]).write(to: path)
    }

    private func requireRefusal(_ fixture: OSDIPrecisionCLIFixture, code: String) async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_CLI_EXECUTABLE"])
        for command in ["-b", "prepared"] {
            let arguments = [command, fixture.deck.path, "--osdi-catalog", fixture.catalog.path,
                "--csv", fixture.csv.path, "--paired-csv", fixture.pairedCSV.path, "--json"]
            // The existing actual-process helper owns a 15-second negative-command timeout.
            let result = try await OSDICLIExecutionTests().process(executable: executable, arguments: arguments)
            try #require(result.status == 2, "\(command): \(result.text)")
            let bytes = Data(result.text.utf8)
            let failure = try JSONDecoder().decode(CoreSpiceCLIFailure.self, from: bytes)
            #expect(failure.status == "failed" && failure.code == code, "\(command): \(result.text)")
            #expect(!failure.message.isEmpty && failure.stage != nil)
            let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            for key in ["osdiExecution", "osdiModels", "osdiVariables", "waveform", "configurationIdentity"] {
                #expect(json[key] == nil, "Failure published partial completion field \(key)")
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.csv.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.pairedCSV.path))
        }
    }
}

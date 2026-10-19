import Foundation
import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceOSDITestSupport
import OSDIContracts
import Testing

@Suite("Shared precision CLI fixture inputs", .timeLimit(.minutes(1)))
struct OSDIPrecisionCLISharedFixtureTests {
    @Test func allSixModelsPreserveExactArtifactsAndCatalogBindings() async throws {
        let manifest = try precisionManifest()
        #expect(Set(manifest.models.map(\.id)) == ["bsim", "cmg", "img", "soi", "compound", "context"])
        for model in manifest.models {
            let root = temporaryRoot()
            defer { cleanup(root) }
            let fixture = try await OSDIPrecisionCLIFixture.make(modelID: model.id, manifest: manifest, root: root)
            let record = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: fixture.catalog))
            #expect(record.schemaVersion == 2)
            #expect(record.libraryRootPath == root.path && record.stagingParentDirectory == root.path)
            #expect(record.executionBudget == fixture.executionBudget)
            #expect(Set(record.executionBudget.keys) == ["maximumNativeAllocationBytes", "maximumLiveOwnedBytes", "maximumTemporaryBytes", "maximumHashedBytes", "maximumEvidenceBytes"])
            #expect(record.executionBudget.values.allSatisfy { $0 > 0 })
            #expect(record.artifacts.count == 1 && record.instances.count == 1)
            let artifact = try #require(record.artifacts.first)
            let instance = try #require(record.instances.first)
            #expect(instance.artifact == artifact.reference)
            #expect(instance.descriptorIndex == model.descriptorIndex && instance.expectedDescriptorName == model.descriptorName)
            #expect(artifact.reference.digest.hexadecimalValue == model.sha256 && artifact.reference.byteCount == model.byteCount)
            try checkCopiedArtifact(root.appendingPathComponent(artifact.relativePath.joined(separator: "/")), sha256: model.sha256, byteCount: model.byteCount)
            let precision = record.transientPrecision
            #expect(precision.workerRootPath == root.path)
            #expect(precision.semanticProfileSHA256 == manifest.semanticProfileSHA256)
            #expect(precision.numericProfileSHA256 == manifest.numericProfileSHA256 && precision.precisionBits == manifest.precisionBits)
            #expect(try precision.options.value() == manifest.options.value())
            #expect(precision.worker.reference.digest.hexadecimalValue == manifest.worker.sha256)
            #expect(precision.worker.reference.byteCount == manifest.worker.byteCount)
            try checkCopiedArtifact(fixture.workerPath, sha256: manifest.worker.sha256, byteCount: manifest.worker.byteCount)
            #expect(precision.worker.relativePath == [fixture.workerPath.lastPathComponent])
            let source = try String(contentsOf: fixture.deck, encoding: .utf8)
            #expect(source.contains(".model \(instance.modelName) osdi\n"))
            let deviceLine = try #require(source.components(separatedBy: "\n").first { $0.lowercased().hasPrefix(instance.instanceName + " ") })
            #expect(deviceLine.hasSuffix(" " + instance.modelName))
            #expect(source.contains(".tran ") && source.hasSuffix(".end\n"))
            #expect(!FileManager.default.fileExists(atPath: fixture.csv.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.pairedCSV.path))
        }
    }

    @Test func fullScheduleRetainsIndependentOriginalStopAndUnknownModelCreatesNothing() async throws {
        let manifest = try precisionManifest()
        let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_ANALYSIS_MANIFEST"])
        let analysis = try JSONDecoder().decode(OSDIAnalysisManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let point = try #require(analysis.cases.first { $0.id == "bsim-n-loaded-s4-transient" })
        let steps = try #require(point.input.analysis.steps)
        let first = try #require(steps.first), last = try #require(steps.last)
        #expect(last.timeSeconds > first.timeSeconds)
        let root = temporaryRoot()
        defer { cleanup(root) }
        let fixture = try await OSDIPrecisionCLIFixture.make(modelID: "bsim", manifest: manifest, root: root, pointID: point.id, pilot: false)
        let source = try String(contentsOf: fixture.deck, encoding: .utf8)
        let command = try #require(source.components(separatedBy: "\n").first { $0.hasPrefix(".tran ") })
        let tokens = command.split(separator: " ")
        #expect(tokens.count >= 5)
        #expect(Double(tokens[1]) == first.timeStepSeconds)
        #expect(Double(tokens[2]) == last.timeSeconds)
        #expect(Double(tokens[4]) == first.timeStepSeconds)
        let unknownRoot = temporaryRoot()
        do {
            _ = try await OSDIPrecisionCLIFixture.make(modelID: "unknown", manifest: manifest, root: unknownRoot)
            Issue.record("Unknown model produced a fixture")
        } catch OSDIDCManifest.Failure.invalidManifest {}
        #expect(!FileManager.default.fileExists(atPath: unknownRoot.path))
    }

    @Test func topologyWitnessRequiresExactPrecisionImageAndDescriptor() throws {
        let precision = try precisionManifest()
        let model = try #require(precision.models.first { $0.id == "soi" })
        let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_PRECISION_DC_MANIFEST"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let manifest = try JSONDecoder().decode(OSDIDCManifest.self, from: bytes)
        let sample = try #require(manifest.cases.first { $0.input.devices.contains { $0.library == model.id } })
        let device = try #require(sample.input.devices.first { $0.library == model.id })
        let witness = try OSDIPrecisionCLIFixture.metadataWitness(for: model,
            connectedTerminalCount: device.connectedTerminalCount, manifest: manifest)
        #expect(witness.rawNodes.count >= device.connectedTerminalCount)

        let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let libraries = try #require(original["libraries"] as? [[String: Any]])
        let index = try #require(libraries.firstIndex { $0["id"] as? String == model.id })
        let replacements: [(String, Any)] = [("id", "wrong-image"), ("sha256", String(repeating: "0", count: 64)),
            ("descriptorIndex", model.descriptorIndex + 1), ("descriptorName", "wrong-descriptor")]
        for (field, value) in replacements {
            var changed = original, changedLibraries = libraries
            changedLibraries[index][field] = value
            changed["libraries"] = changedLibraries
            let decoded = try JSONDecoder().decode(OSDIDCManifest.self,
                from: JSONSerialization.data(withJSONObject: changed))
            #expect(throws: OSDIDCManifest.Failure.self) {
                try OSDIPrecisionCLIFixture.metadataWitness(for: model,
                    connectedTerminalCount: device.connectedTerminalCount, manifest: decoded)
            }
        }
        for field in ["libraries", "cases"] {
            var missing = original
            missing[field] = [] as [Any]
            let decoded = try JSONDecoder().decode(OSDIDCManifest.self,
                from: JSONSerialization.data(withJSONObject: missing))
            #expect(throws: OSDIDCManifest.Failure.self) {
                try OSDIPrecisionCLIFixture.metadataWitness(for: model,
                    connectedTerminalCount: device.connectedTerminalCount, manifest: decoded)
            }
        }
    }

    private func precisionManifest() throws -> OSDIPrecisionManifest {
        let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_PRECISION_MANIFEST"])
        return try JSONDecoder().decode(OSDIPrecisionManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func checkCopiedArtifact(_ path: URL, sha256: String, byteCount: UInt64) throws {
        let bytes = try Data(contentsOf: path)
        #expect(UInt64(bytes.count) == byteCount)
        let digest = try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: byteCount, maximumTotalByteCount: byteCount, maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in try lease.update(Array(bytes))
        }
        #expect(digest.digest.hexadecimalValue == sha256)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("osdi-precision-shared-\(UUID().uuidString)")
    }
    private func cleanup(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Shared precision fixture cleanup failed: \(error)") }
    }

    private struct Catalog: Decodable {
        let schemaVersion: Int
        let libraryRootPath: String
        let stagingParentDirectory: String
        let executionBudget: [String: UInt64]
        let artifacts: [Artifact]
        let instances: [Instance]
        let transientPrecision: Precision
        struct Artifact: Decodable { let reference: ArtifactReference; let relativePath: [String] }
        struct Instance: Decodable {
            let instanceName: String
            let modelName: String
            let artifact: ArtifactReference
            let descriptorIndex: Int
            let expectedDescriptorName: String
        }
        struct Precision: Decodable {
            let workerRootPath: String
            let worker: Artifact
            let semanticProfileSHA256: String
            let numericProfileSHA256: String
            let precisionBits: UInt32
            let options: OSDIPrecisionManifest.Options
        }
    }
}

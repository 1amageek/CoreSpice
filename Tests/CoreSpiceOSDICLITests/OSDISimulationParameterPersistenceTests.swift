import CircuiteFoundation
import CircuiteFoundationCrypto
import CircuiteFoundationFoundation
import CircuiteFoundationFileSystem
import CoreSpiceIO
import CoreSpiceOSDIContracts
import Foundation
import OSDIContracts
import Testing
@testable import CoreSpice
@testable import CoreSpiceCLICore

/// Persistence fixtures exercise typed receipt projection, not model execution authority.
@Suite("Exact OSDI simulation-parameter CLI persistence", .timeLimit(.minutes(1)))
struct OSDISimulationParameterPersistenceTests {
    private func parameters() throws -> [OSDISimulationParameter] {
        try [.init(name: "tnom", value: .real(-0.0)),
             .init(name: "mode", value: .string("e\u{301}/\"\n"))]
    }

    private func record(_ parameters: [OSDISimulationParameter], phase: String = "op") throws -> CoreSpiceCLIOSDIRecord {
        let artifact = try ArtifactReference(digest: .init(algorithm: .sha256, hexadecimalValue: String(repeating: "a", count: 64)),
            byteCount: 1, descriptor: .init(role: .input, kind: .model, format: .unknown))
        let binding = try OSDIModelBinding(modelName: "fixture", artifact: artifact,
            descriptorIndex: 0, expectedDescriptorName: "fixture", modelParameters: [])
        let resolved = try OSDIResolvedInstance(binding: binding, instanceParameters: [], previousState: [])
        let nature = try OSDINatureReference(kind: 0, index: 0)
        let node = try OSDINodeInfo(index: 0, name: "p", units: "V", residualUnits: "A", isFlow: false,
            unknownNature: nature, residualNature: nature, activeUnknownIndex: 0)
        let topology = try OSDIPreparedTopology(nodes: [node], activeUnknownCount: 1, stateCount: 0)
        let receipt = try OSDIPreparationReceipt(resolved: resolved, effectiveTemperatureKelvin: 300,
            topology: topology, resolvedParameters: [], simulationParameters: parameters)
        let native = NativeOSDIPreparationRecord(instanceName: "N1", receipt: receipt,
            rawNodeGlobalRows: [0], transientPrecision: nil)
        return try .init(phase: phase, completed: native, completedPointCount: 1,
            sourceName: phase == "dc" ? "V1" : nil, sourceValue: phase == "dc" ? -0.0 : nil,
            sourcePointIndex: phase == "dc" ? 0 : nil)
    }

    private func object(_ record: CoreSpiceCLIOSDIRecord) throws -> [String: Any] {
        let data = Data(try CoreSpiceCLIJSON.encode(record).utf8)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func decode(_ object: [String: Any]) throws -> CoreSpiceCLIOSDIRecord {
        try JSONDecoder().decode(CoreSpiceCLIOSDIRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func requireRefusal(_ object: [String: Any]) throws {
        do { _ = try decode(object); Issue.record("Expected exact model evidence refusal") }
        catch is DecodingError { }
        catch let error as CoreSpiceCLIOSDIError {
            guard case .incompleteReceipt = error else { throw error }
        }
    }

    @Test func typedReceiptColdRoundtripPreservesOriginalPhaseAndExactValues() throws {
        let expected = try parameters()
        for (phase, schema, profile) in [("op", 1, "nativeOSDI.op.v1"),
            ("ac", 2, "nativeOSDI.analysis.v2"), ("tran", 2, "nativeOSDI.analysis.v2"),
            ("noise", 2, "nativeOSDI.analysis.v2"), ("tf", 3, "nativeOSDI.analysis.v3"),
            ("pz", 3, "nativeOSDI.analysis.v3"), ("sens", 3, "nativeOSDI.analysis.v3"),
            ("sens-ac", 3, "nativeOSDI.analysis.v3"), ("fourier", 3, "nativeOSDI.analysis.v3"),
            ("dc", 4, "nativeOSDI.dc.v4"), ("network", 5, "nativeOSDI.network.v5")] {
            let original = try record(expected, phase: phase)
            let bytes = Data(try CoreSpiceCLIJSON.encode(original).utf8)
            let cold = try JSONDecoder().decode(CoreSpiceCLIOSDIRecord.self, from: bytes)
            #expect(cold == original)
            #expect(cold.schemaVersion == 6 && cold.phaseSchemaVersion == schema && cold.phaseProfile == profile)
            #expect(cold.simulationParameters[0].realValueBits == (-0.0).bitPattern)
            let actual = try cold.simulationParameters.map { try $0.simulationParameter() }
            #expect(OSDIPreparationReceipt.simulationParametersEqual(actual, expected))
            #expect(cold.effectiveKelvin == 300)
            if phase == "dc" { #expect(cold.sourceValueBits == (-0.0).bitPattern) }
            let savedAgain = try CoreSpiceCLIJSON.encode(cold)
            #expect(Data(savedAgain.utf8) == bytes)
        }
    }

    @Test func legacyEmptyRecordsOmitExtensionAndKeepCanonicalWireBytes() throws {
        for phase in ["op", "ac", "tran", "noise", "tf", "pz", "sens", "sens-ac", "fourier", "dc", "network"] {
            let original = try record([], phase: phase)
            let saved = try CoreSpiceCLIJSON.encode(original)
            let wire = try object(original)
            #expect(wire["simulationParameters"] == nil && wire["phaseSchemaVersion"] == nil && wire["phaseProfile"] == nil)
            #expect(original.schemaVersion == original.phaseSchemaVersion)
            let cold = try decode(wire)
            #expect(cold.simulationParameters.isEmpty)
            let again = try CoreSpiceCLIJSON.encode(cold)
            #expect(again == saved)
            // The original synthesized encoder writes exactly these stored legacy fields.
            let legacy = LegacyEncoding(value: original)
            let legacyBytes = try CoreSpiceCLIJSON.encode(legacy)
            #expect(legacyBytes == saved)
        }
    }

    @Test func decomposedNamesRemainByteDistinctAndOrderedThroughColdDecode() throws {
        let a = try OSDISimulationParameter(name: "e\u{301}", value: .real(-0.0))
        let b = try OSDISimulationParameter(name: "\u{e9}", value: .real(-0.0))
        let first = try record([a]), second = try record([b])
        #expect(first.simulationParameters != second.simulationParameters)
        let cold = try decode(object(first))
        #expect(cold.simulationParameters[0].name.utf8.elementsEqual(a.name.utf8))
        #expect(!cold.simulationParameters[0].name.utf8.elementsEqual(b.name.utf8))
        #expect(Set([first.simulationParameters[0], second.simulationParameters[0]]).count == 2)
    }

    @Test func extensionMissingBaseWrongPhaseAndLegacySplicingAreRefused() throws {
        let original = try object(record(parameters()))
        for key in ["simulationParameters", "phaseSchemaVersion", "phaseProfile"] {
            var changed = original; changed.removeValue(forKey: key); try requireRefusal(changed)
        }
        var changed = original; changed["simulationParameters"] = []; try requireRefusal(changed)
        changed = original; changed["phaseSchemaVersion"] = 2; try requireRefusal(changed)
        changed = original; changed["phaseProfile"] = "nativeOSDI.analysis.v2"; try requireRefusal(changed)
        changed = original; changed["phase"] = "unknown"; try requireRefusal(changed)
        changed = original; changed["profile"] = "nativeOSDI.op.v1"; try requireRefusal(changed)
        changed = original; changed["schemaVersion"] = 1; changed["profile"] = "nativeOSDI.op.v1"; try requireRefusal(changed)
        changed = try object(record([])); changed["simulationParameters"] = []; try requireRefusal(changed)
    }

    @Test func malformedTypedPayloadsAndDuplicateNamesAreRefused() throws {
        let original = try object(record(parameters()))
        var values = try #require(original["simulationParameters"] as? [[String: Any]])
        var changed = original
        values[0]["type"] = "integer"; changed["simulationParameters"] = values; try requireRefusal(changed)
        values = try #require(original["simulationParameters"] as? [[String: Any]])
        values[0]["stringValue"] = NSNull(); changed["simulationParameters"] = values; try requireRefusal(changed)
        values = try #require(original["simulationParameters"] as? [[String: Any]])
        values[1]["name"] = "tnom"; changed["simulationParameters"] = values; try requireRefusal(changed)
        values = try #require(original["simulationParameters"] as? [[String: Any]])
        values[0]["realValueBits"] = UInt64.max; changed["simulationParameters"] = values
        #expect(throws: OSDIContractError.invalidParameterValue) { try decode(changed) }
    }

    private func execution() throws -> CoreSpiceCLIOSDIExecutionRecord {
        let json = #"{"schemaVersion":1,"analysis":"ac","rows":[{"row":0,"kind":"node","unit":"V"}],"columns":[{"name":"V(p)","unit":"V","compiledRow":0}],"sweepName":"frequency","sweepUnit":"Hz","coordinates":[1000],"real":[1],"imaginary":[0],"operatingPoint":[1],"acceptedSteps":[],"projectedColumns":[0]}"#
        return try JSONDecoder().decode(CoreSpiceCLIOSDIExecutionRecord.self, from: Data(json.utf8))
    }

    @Test func actualPhaseJoinRejectsValueTypeOrderAndUTF8Tampering() throws {
        let expected = try parameters(), op = try record(expected), outer = try record(expected, phase: "ac")
        let completed = try execution()
        try completed.validate(models: [op, outer])
        let alternatives: [[OSDISimulationParameter]] = [
            try [.init(name: "tnom", value: .real(0.0)), expected[1]],
            try [.init(name: "tnom", value: .string("0")), expected[1]],
            [expected[1], expected[0]],
            try [expected[0], .init(name: "mode", value: .string("\u{e9}/\"\n"))],
            try [.init(name: "TNOM", value: .real(-0.0)), expected[1]]
        ]
        for alternative in alternatives {
            let changed = try record(alternative, phase: "ac")
            #expect(changed.simulationParameters != outer.simulationParameters)
            do { try completed.validate(models: [op, changed]); Issue.record("Changed simulation context passed phase join") }
            catch let error as CoreSpiceCLIOSDIError { guard case .incompleteReceipt = error else { throw error } }
        }
    }

    @Test func genericSerializationVisitorCountsExtensionAndPreservesResourceCancellation() async throws {
        let nonempty = try record(parameters()), empty = try record([])
        let resources = try SPICESimulationResources(maximumLiveBytes: 1 << 20, maximumTemporaryBytes: 1 << 20,
            maximumWorkUnits: 1 << 20, maximumHashedBytes: 1 << 20)
        let upper = try CoreSpiceCLIJSONUpperBound.count(nonempty, maximumBytes: 1 << 20, resources: resources)
        let oldUpper = try CoreSpiceCLIJSONUpperBound.count(empty, maximumBytes: 1 << 20, resources: resources)
        let bytes = try CoreSpiceCLIJSON.encode(nonempty)
        #expect(upper > oldUpper && upper >= UInt64(bytes.utf8.count))
        do {
            _ = try CoreSpiceCLIJSONUpperBound.count(nonempty, maximumBytes: upper - 1, resources: resources)
            Issue.record("Extension exceeded caller serialization ceiling")
        } catch let error as CoreSpiceCLIOSDIError { guard case .incompleteReceipt = error else { throw error } }
        let cancelled = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try CoreSpiceCLIJSONUpperBound.count(nonempty, maximumBytes: 1 << 20, resources: resources)
                Issue.record("Cancelled serialization visitor succeeded")
            } catch let error as SPICESimulationResources.ResourceError {
                guard case .cancelled = error else { throw error }
            }
        }
        try await cancelled.value
    }

    private struct LiveFixture {
        let directory: URL
        let deck: URL
        let catalog: URL
        let parameters: [OSDISimulationParameter]
    }

    private func liveFixture() throws -> LiveFixture {
        let source = try #require(ProcessInfo.processInfo.environment["CORESPICE_GLOBAL_CHARGE_LINEAR_LIBRARY"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simulation-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let image = directory.appendingPathComponent("linear.osdi")
            try FileManager.default.copyItem(atPath: source, toPath: image.path)
            let reference = try LocalArtifactReferencer(digester: SHA256ContentDigester()).reference(
                ArtifactLocator(location: ArtifactLocation(workspaceRelativePath: "linear.osdi"),
                    role: .input, kind: .model, format: .raw), relativeTo: directory)
            try #require(reference.digest.hexadecimalValue == "25f3f51c385252ce34876ca990aa6e932bf7a4c1948237b0100d03749158d846")
            let helper = OSDICLIExecutionTests()
            let values = try parameters()
            let simulations = try values.map { try helper.object(CoreSpiceCLIOSDISimulationParameterRecord($0)) }
            let model = [
                try OSDIParameterAssignment(name: "conductance", scope: .model, value: .real(1)),
                try OSDIParameterAssignment(name: "capacitance", scope: .model, value: .real(2))]
            let assignments = try model.map { try helper.object(CoreSpiceCLIOSDIParameterRecord($0)) }
            let json: [String: Any] = [
                "schemaVersion": 3, "baseCatalogSchemaVersion": 1, "simulationParameters": simulations,
                "libraryRootPath": directory.path, "stagingParentDirectory": directory.path,
                "artifacts": [["reference": try helper.object(reference), "relativePath": ["linear.osdi"],
                    "accessBudget": ["maximumPageByteCount": 65536, "maximumTotalByteCount": 16777216,
                        "maximumPageCount": 4096, "maximumWorkUnitCount": 8192, "maximumDurationNanoseconds": 5000000000]]],
                "instances": [["instanceName": "nq", "modelName": "q", "artifact": try helper.object(reference),
                    "descriptorIndex": 0, "expectedDescriptorName": "linear_rc", "modelParameters": assignments,
                    "instanceParameters": [], "previousState": []]],
                "loadLimits": ["maximumDescriptors": 4, "maximumMetadataBytes": 1048576, "maximumStorageBytes": 1048576],
                "evaluationLimits": ["maximumWorkspaceBytes": 1048576, "maximumDiagnosticCount": 256,
                    "maximumDiagnosticBytes": 65536, "maximumStringBytes": 65536],
                "maximumInstanceCount": 1, "maximumAdapterBytes": 16777216,
                "tolerances": ["temperatureAbsoluteKelvin": 1e-6, "thermalResidualAbsoluteWatts": 1e-12]]
            let deck = directory.appendingPathComponent("input.cir"), catalog = directory.appendingPathComponent("catalog.json")
            try "explicit simulation transport\n.temp 27\n.options gmin=0\n.model q osdi\nNq p 0 q\nV1 p 0 1\n.op\n.end\n".write(to: deck, atomically: true, encoding: .utf8)
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: catalog)
            return .init(directory: directory, deck: deck, catalog: catalog, parameters: values)
        } catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch let cleanup { Issue.record("Live fixture cleanup failed: \(cleanup)") }
            throw error
        }
    }
    private func remove(_ fixture: LiveFixture) {
        do { try FileManager.default.removeItem(at: fixture.directory) }
        catch { Issue.record("Live CLI fixture cleanup failed: \(error)") }
    }

    @Test func actualNativePreparationToCLIFileColdReloadAndRetainedRerun() async throws {
        // The pinned existing linear model may ignore these parameters physically;
        // this test owns transport/persistence, not their physical influence.
        let fixture = try liveFixture()
        defer { remove(fixture) }
        let completed = try await CoreSpicePreparedCommand(arguments: [fixture.deck.path,
            "--osdi-catalog", fixture.catalog.path, "--json"]).executeWithRecord()
        let live = try #require(completed.output.prepared.osdiPreparationRecords.first)
        #expect(OSDIPreparationReceipt.simulationParametersEqual(live.receipt.simulationParameters, fixture.parameters))
        let projected = try CoreSpiceCLIOSDIRecord(phase: "op", completed: live, completedPointCount: 1)
        #expect(completed.record.osdiModels == [projected] && projected.schemaVersion == 6)
        let text = try CoreSpiceCLIJSON.encode(completed.record)
        let saved = fixture.directory.appendingPathComponent("prepared.json")
        try Data(text.utf8).write(to: saved, options: .atomic)
        let count = UInt64(text.utf8.count)
        #expect(throws: SPICESourceCaptureError.totalByteLimitExceeded(limit: count - 1, requested: count)) {
            try LocalSPICESourceReader().read(at: saved.path, maximumByteCount: count - 1, maximumPageByteCount: 4096)
        }
        let bytes = try LocalSPICESourceReader().read(at: saved.path, maximumByteCount: count, maximumPageByteCount: 4096)
        let cold = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: bytes)
        #expect(cold.osdiModels == [projected] && cold.configurationIdentity == completed.record.configurationIdentity)
        let again = try CoreSpiceCLIJSON.encode(cold)
        #expect(Data(again.utf8) == bytes)
        let native = SPICENativeSimulation()
        let prepared = try await native.prepare(completed.output.prepared.input, limits: completed.output.prepared.limits,
            osdi: try #require(completed.output.prepared.osdiRuntimeInputs))
        let rerun = try await native.execute(prepared, cancellation: .init())
        let replayed = try CoreSpiceCLIPreparedRunRecord(rerun)
        #expect(replayed.osdiModels == cold.osdiModels && replayed.configurationIdentity == cold.configurationIdentity)
    }

    @Test func realPreparedAndBatchCommandsAcceptExplicitCatalogAndPersistSchemaSix() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_CLI_EXECUTABLE"])
        let fixture = try liveFixture()
        defer { remove(fixture) }
        let helper = OSDICLIExecutionTests()
        for mode in ["prepared", "-b"] {
            let result = try await helper.process(executable: executable, arguments: [mode, fixture.deck.path,
                "--osdi-catalog", fixture.catalog.path, "--json"])
            try #require(result.status == 0, "Actual CLI refused explicit simulation catalog: \(result.text)")
            let saved = fixture.directory.appendingPathComponent(mode == "prepared" ? "executable-prepared.json" : "executable-batch.json")
            try Data(result.text.utf8).write(to: saved, options: .atomic)
            let bytes = try LocalSPICESourceReader().read(at: saved.path, maximumByteCount: 1048576, maximumPageByteCount: 4096)
            let models: [CoreSpiceCLIOSDIRecord]
            if mode == "prepared" {
                models = try #require(JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: bytes).osdiModels)
            } else {
                models = try #require(JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: bytes).osdiModels)
            }
            let actual = try #require(models.first)
            #expect(models.count == 1 && actual.schemaVersion == 6 && actual.phaseSchemaVersion == 1)
            let values = try actual.simulationParameters.map { try $0.simulationParameter() }
            #expect(OSDIPreparationReceipt.simulationParametersEqual(values, fixture.parameters))
        }
    }

    @Test func catalogExtensionRefusesLegacySplicingMissingValuesAndUnknownBasesBeforeAcquisition() throws {
        // These malformed envelopes deliberately have no paths, artifacts or provider inputs.
        // Refusal must occur at the extension contract, before those fields are decoded.
        let real: [[String: Any]] = [["name": "gain", "type": "real", "realValueBits": 0]]
        let malformed: [[String: Any]] = [
            ["schemaVersion": 1, "simulationParameters": real],
            ["schemaVersion": 2, "simulationParameters": NSNull()],
            ["schemaVersion": 3, "simulationParameters": real],
            ["schemaVersion": 3, "baseCatalogSchemaVersion": 99, "simulationParameters": real],
            ["schemaVersion": 3, "baseCatalogSchemaVersion": 1],
            ["schemaVersion": 3, "baseCatalogSchemaVersion": 1, "simulationParameters": []],
            ["schemaVersion": 3, "baseCatalogSchemaVersion": 1, "simulationParameters": NSNull()]]
        for object in malformed {
            do {
                _ = try JSONDecoder().decode(CoreSpiceCLIOSDICatalog.self, from: JSONSerialization.data(withJSONObject: object))
                Issue.record("Malformed simulation catalog passed intake")
            } catch let failure as CoreSpiceCLIOSDIError {
                guard case .invalidCatalog = failure else { throw failure }
            } catch let failure as DecodingError {
                switch failure {
                case .keyNotFound(let key, _): #expect(["baseCatalogSchemaVersion", "simulationParameters"].contains(key.stringValue))
                case .valueNotFound(_, let context): #expect(context.codingPath.last?.stringValue == "simulationParameters")
                default: throw failure
                }
            }
        }
    }

    /// Independent original-schema encoder: the extension has no representation here.
    private struct LegacyEncoding: Encodable {
        let value: CoreSpiceCLIOSDIRecord
        private enum Key: String, CodingKey {
            case schemaVersion, profile, phase, sourceName, sourcePointIndex, sourceValueBits
            case instanceName, modelName, artifact, descriptorIndex, expectedDescriptorName
            case modelParameters, instanceParameters, previousState, resolvedParameters, effectiveKelvin
            case rawNodeGlobalRows, rawNodeNames, rawNodeUnits, rawEquationUnits, completedPointCount
        }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(value.schemaVersion, forKey: .schemaVersion); try c.encode(value.profile, forKey: .profile)
            try c.encode(value.phase, forKey: .phase)
            try c.encodeIfPresent(value.sourceName, forKey: .sourceName)
            try c.encodeIfPresent(value.sourcePointIndex, forKey: .sourcePointIndex)
            try c.encodeIfPresent(value.sourceValueBits, forKey: .sourceValueBits)
            try c.encode(value.instanceName, forKey: .instanceName); try c.encode(value.modelName, forKey: .modelName)
            try c.encode(value.artifact, forKey: .artifact); try c.encode(value.descriptorIndex, forKey: .descriptorIndex)
            try c.encode(value.expectedDescriptorName, forKey: .expectedDescriptorName)
            try c.encode(value.modelParameters, forKey: .modelParameters); try c.encode(value.instanceParameters, forKey: .instanceParameters)
            try c.encode(value.previousState, forKey: .previousState); try c.encode(value.resolvedParameters, forKey: .resolvedParameters)
            try c.encode(value.effectiveKelvin, forKey: .effectiveKelvin); try c.encode(value.rawNodeGlobalRows, forKey: .rawNodeGlobalRows)
            try c.encode(value.rawNodeNames, forKey: .rawNodeNames); try c.encode(value.rawNodeUnits, forKey: .rawNodeUnits)
            try c.encode(value.rawEquationUnits, forKey: .rawEquationUnits); try c.encode(value.completedPointCount, forKey: .completedPointCount)
        }
    }
}

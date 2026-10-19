import CircuiteFoundation
import CoreSpice
import CryptoKit
import CoreSpiceDevices
import CoreSpiceExporterCSV
import CoreSpiceIO
import CoreSpiceOSDI
import CoreSpiceOSDITestSupport
import Foundation
import OSDIContracts
import SignoffToolSupport
import Testing
@testable import CoreSpiceCLICore

@Suite("Latest SOI 101 compensated circuit evidence", .serialized, .timeLimit(.minutes(24)))
struct OSDISoi101PrecisionCLITests {
    private struct Inputs: Decodable {
        struct Case: Decodable {
            let id: String
            let directory: String
            let deck: OSDIPrecisionManifest.Artifact
            let input: Input
            struct Input: Decodable { let circuit: OSDIDCManifest.Input }
        }
        let schema: String
        let precisionManifest: String
        let cases: [Case]
    }

    @Test(.timeLimit(.minutes(20))) func fullNPD() async throws { try await run("soi101-n-pd-transient") }
    @Test(.timeLimit(.minutes(20))) func fullNDD() async throws { try await run("soi101-n-dd-transient") }
    @Test(.timeLimit(.minutes(20))) func fullPPD() async throws { try await run("soi101-p-pd-transient") }
    @Test(.timeLimit(.minutes(20))) func fullPDD() async throws { try await run("soi101-p-dd-transient") }

    @Test(.timeLimit(.minutes(24))) func remainingNDD() async throws {
        try await run("soi101-n-dd-transient", continuation: true)
    }
    @Test(.timeLimit(.minutes(24))) func remainingPDD() async throws {
        try await run("soi101-p-dd-transient", continuation: true)
    }

    @Test(.timeLimit(.minutes(1))) func rejectsChangedAPIWitnessDigestBeforeExecution() throws {
        let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_SOI101_API_WITNESS"])
        let witness = try JSONDecoder().decode(APIWitness.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let original = try #require(witness.cases.first).preparedAPI
        let changedDigest = (original.sha256.first == "0" ? "1" : "0") + String(original.sha256.dropFirst())
        let changed = WitnessArtifact(path: original.path, sha256: changedDigest, byteCount: original.byteCount)
        #expect(throws: WitnessFailure.self) { _ = try checkedArtifact(changed) }
    }

    private func run(_ id: String, continuation: Bool = false) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_SOI101_QUALIFICATION"])
        let inputs = try JSONDecoder().decode(Inputs.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try #require(inputs.schema == "corespice.soi101.precision-qualification.v1")
        try #require(Set(inputs.cases.map(\.id)) == Set(["soi101-n-pd-transient", "soi101-n-dd-transient", "soi101-p-pd-transient", "soi101-p-dd-transient"]))
        let selected = try #require(inputs.cases.first { $0.id == id })
        let manifest = try JSONDecoder().decode(OSDIPrecisionManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: inputs.precisionManifest)))
        let root = URL(fileURLWithPath: selected.directory, isDirectory: true)
        let deck = URL(fileURLWithPath: selected.deck.path)
        let source = try String(contentsOf: deck, encoding: .utf8)
        try #require(source.contains(".tran 1e-10 2e-9 0 1e-10"))
        try #require(selected.input.circuit.policy.equationAbsoluteTolerances == ["A": 1e-12, "V": 1e-10, "W": 1e-12])
        let catalog: URL
        let preparedReload: CoreSpiceCLIPreparedRunRecord
        let limits: SPICENativeExecutionLimits
        if continuation {
            let admitted = try admitWitness(id: id, inputPath: path, inputs: inputs, selected: selected, manifest: manifest)
            catalog = admitted.catalog
            preparedReload = admitted.prepared
            limits = admitted.limits
        } else {
            catalog = try await makeCatalog(selected, manifest: manifest)
            let csv = root.appendingPathComponent("api.csv"), paired = root.appendingPathComponent("api-paired.csv")
            let command = CoreSpicePreparedCommand(arguments: [deck.path, "--osdi-catalog", catalog.path,
                "--csv", csv.path, "--paired-csv", paired.path])
            do {
                print("Latest SOI precision \(id): prepared API execute and persist")
                let completed = try await command.executeWithRecord()
                let actual = try #require(completed.record.osdiExecution)
                try check(actual, manifest: manifest, selected: selected)
                preparedReload = try persist(completed.record, to: root.appendingPathComponent("prepared-api.json"))
                #expect(preparedReload.osdiExecution == actual)
                try checkPaired(paired, execution: actual)
                limits = completed.output.prepared.limits
            }
        }
        let expected = try #require(preparedReload.osdiExecution)
        let budget = try #require(CoreSpiceCLIOSDICatalog.load(path: catalog.path).executionBudget)
        let native = SPICENativeSimulation()
        if !continuation {
            print("Latest SOI precision \(id): direct Native prepare")
            let prepared = try await prepareNative(selected, catalog: catalog, limits: limits)
            print("Latest SOI precision \(id): direct Native execute")
            let direct = try await native.execute(prepared, cancellation: .init())
            print("Latest SOI precision \(id): direct Native record and persist")
            let api = try CoreSpiceCLIPreparedRunRecord(direct, budget: budget)
            #expect(api.osdiExecution == expected)
            let apiReload = try persist(api, to: root.appendingPathComponent("api.json"))
            #expect(apiReload.osdiExecution == expected)
        }
        try expectReleased(root)
        let token = CancellationToken(); token.cancel()
        let cancelled = try await prepareNative(selected, catalog: catalog, limits: limits)
        do {
            _ = try await native.execute(cancelled, cancellation: token)
            Issue.record("Cancelled latest SOI precision run published completion")
        } catch SPICENativeExecutionError.cancelled {}
        try expectReleased(root)
        for lane in ["batch", "prepared"] {
            let output = root.appendingPathComponent(lane + ".json")
            let laneCSV = root.appendingPathComponent(lane + ".csv")
            let lanePaired = root.appendingPathComponent(lane + "-paired.csv")
            let arguments = (lane == "batch" ? ["-b"] : ["prepared"]) + [deck.path,
                "--osdi-catalog", catalog.path, "--csv", laneCSV.path, "--paired-csv", lanePaired.path, "--json"]
            try await process(arguments, output: output, maximumOutputBytes: budget.maximumEvidenceBytes)
            if lane == "batch" {
                let record = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: Data(contentsOf: output))
                #expect(record.status == "succeeded" && record.osdiExecution == expected)
                let persisted = root.appendingPathComponent("batch-reloaded.json")
                let reloaded = try persist(record, to: persisted)
                #expect(reloaded == record)
            } else {
                let record = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(contentsOf: output))
                #expect(record.osdiExecution == expected)
                let reloaded = try persist(record, to: root.appendingPathComponent("prepared-reloaded.json"))
                #expect(reloaded.osdiExecution == expected && reloaded.osdiModels == record.osdiModels)
            }
            try checkPaired(lanePaired, execution: expected)
            let display = try CSVWaveformReader().read(contentsOfFile: laneCSV.path)
            #expect(display.pointCount == expected.coordinates.count && display.variableCount == expected.columns.count)
            for column in expected.columns.indices {
                #expect(display.variables[column].name == expected.columns[column].name)
                #expect(display.variables[column].unit.rawValue == expected.columns[column].unit)
                for point in expected.coordinates.indices {
                    let high = expected.real[point * expected.columns.count + column]
                    let value = try #require(display.realValue(variable: column, point: point))
                    #expect(abs(value - high) <= max(abs(high) * 8e-15, Double.leastNonzeroMagnitude))
                }
            }
            try expectReleased(root)
        }
        try await refuseExhaustedWorker(selected, catalog: catalog)
        // A successful fresh run after cancellation and worker failure also proves owners were released.
        let afterFailure = try await prepareNative(selected, catalog: catalog, limits: limits)
        let rerun = try await native.execute(afterFailure, cancellation: .init())
        #expect(try CoreSpiceCLIPreparedRunRecord(rerun, budget: budget).osdiExecution == expected)
        try expectReleased(root)
        print("Latest SOI precision \(id): \(expected.acceptedSteps.count) full accepted steps, \(expected.rows.count) rows, API/batch/prepared exact persisted candidates")
    }

    private struct WitnessArtifact: Decodable {
        let path: String
        let sha256: String
        let byteCount: UInt64
    }

    private struct APIWitness: Decodable {
        struct Case: Decodable {
            struct NativeLimits: Decodable {
                let maximumDeviceCount: Int
                let maximumMatrixDimension: Int
                let maximumAllocationBytes: UInt64
            }
            let id: String
            let catalog: WitnessArtifact
            let preparedAPI: WitnessArtifact
            let api: WitnessArtifact
            let pairedCSV: WitnessArtifact
            let sourceInputIdentity: String
            let configurationIdentity: String
            let nativeLimits: NativeLimits
        }
        let schema: String
        let inputManifest: WitnessArtifact
        let precisionManifest: WitnessArtifact
        let originalTestBundle: WitnessArtifact
        let executionHelper: WitnessArtifact
        let publicGraphSourceReceipt: WitnessArtifact
        let cases: [Case]
    }

    private enum WitnessFailure: Error {
        case identityMismatch(String)
    }

    private func checkedArtifact(_ artifact: WitnessArtifact) throws -> Data {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: artifact.path))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard UInt64(bytes.count) == artifact.byteCount, digest == artifact.sha256 else {
            throw WitnessFailure.identityMismatch(artifact.path)
        }
        return bytes
    }

    private func admitWitness(id: String, inputPath: String, inputs: Inputs, selected: Inputs.Case,
                              manifest: OSDIPrecisionManifest) throws
        -> (catalog: URL, prepared: CoreSpiceCLIPreparedRunRecord, limits: SPICENativeExecutionLimits) {
        let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_SOI101_API_WITNESS"])
        let witness = try JSONDecoder().decode(APIWitness.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try #require(witness.schema == "corespice.soi101.api-witness.v1")
        try #require(manifest.models.count == 1 && manifest.models[0].id == "soi101")
        try #require(Set(witness.cases.map(\.id)).count == witness.cases.count)
        let prerequisite = try #require(witness.cases.first { $0.id == id })
        func samePath(_ lhs: String, _ rhs: String) -> Bool {
            URL(fileURLWithPath: lhs).standardizedFileURL == URL(fileURLWithPath: rhs).standardizedFileURL
        }
        try #require(samePath(witness.inputManifest.path, inputPath))
        try #require(samePath(witness.precisionManifest.path, inputs.precisionManifest))
        _ = try checkedArtifact(witness.inputManifest)
        _ = try checkedArtifact(witness.precisionManifest)
        _ = try checkedArtifact(witness.originalTestBundle)
        _ = try checkedArtifact(witness.executionHelper)
        _ = try checkedArtifact(witness.publicGraphSourceReceipt)
        let root = URL(fileURLWithPath: selected.directory, isDirectory: true)
        for (artifact, name) in [(prerequisite.catalog, "catalog.json"), (prerequisite.preparedAPI, "prepared-api.json"),
                                 (prerequisite.api, "api.json"), (prerequisite.pairedCSV, "api-paired.csv")] {
            try #require(samePath(artifact.path, root.appendingPathComponent(name).path))
        }
        // Complete byte admission precedes catalog/provider preparation and every numerical lane.
        _ = try checkedArtifact(prerequisite.catalog)
        let preparedBytes = try checkedArtifact(prerequisite.preparedAPI)
        let apiBytes = try checkedArtifact(prerequisite.api)
        _ = try checkedArtifact(prerequisite.pairedCSV)
        for artifact in [selected.deck, manifest.worker, manifest.models[0].source, manifest.models[0].program] {
            _ = try checkedArtifact(.init(path: artifact.path, sha256: artifact.sha256, byteCount: artifact.byteCount))
        }
        let model = manifest.models[0]
        _ = try checkedArtifact(.init(path: model.path, sha256: model.sha256, byteCount: model.byteCount))
        let prepared = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: preparedBytes)
        let api = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: apiBytes)
        let execution = try #require(prepared.osdiExecution)
        let apiExecution = try #require(api.osdiExecution)
        try check(execution, manifest: manifest, selected: selected)
        try check(apiExecution, manifest: manifest, selected: selected)
        try #require(execution == apiExecution && prepared.osdiModels == api.osdiModels)
        let device = try #require(selected.input.circuit.devices.first)
        let assignments = try device.parameters.map { try $0.assignment() }
        for actual in try #require(prepared.osdiModels) {
            try #require(actual.descriptorIndex == device.descriptorIndex && actual.effectiveKelvin == device.temperatureKelvin)
            let modelAssignments = try actual.modelParameters.map { try $0.assignment() }
            let instanceAssignments = try actual.instanceParameters.map { try $0.assignment() }
            try #require(modelAssignments == assignments.filter { $0.scope == .model })
            try #require(instanceAssignments == assignments.filter { $0.scope == .instance })
            try #require(actual.previousState == device.previousState)
        }
        try #require(prepared.sourceInputIdentity == prerequisite.sourceInputIdentity &&
                     api.sourceInputIdentity == prerequisite.sourceInputIdentity)
        try #require(prepared.configurationIdentity == prerequisite.configurationIdentity &&
                     api.configurationIdentity == prerequisite.configurationIdentity)
        try checkPaired(URL(fileURLWithPath: prerequisite.pairedCSV.path), execution: execution)
        let precise = try #require(execution.precision)
        let catalog = URL(fileURLWithPath: prerequisite.catalog.path)
        let loaded = try CoreSpiceCLIOSDICatalog.load(path: catalog.path)
        let budget = try #require(loaded.executionBudget)
        try #require(precise.executionBudget == budget)
        let policy = try CoreSpiceCLIExecutionPolicy.developerV1().applying(budget)
        let bound = prerequisite.nativeLimits
        try #require(bound.maximumDeviceCount == policy.maximumElements &&
                     bound.maximumMatrixDimension == precise.settings.numericalLimits.maximumMatrixDimension &&
                     bound.maximumAllocationBytes == policy.maximumAllocationBytes)
        let limits = SPICENativeExecutionLimits(maximumDeviceCount: bound.maximumDeviceCount,
            maximumMatrixDimension: bound.maximumMatrixDimension, maximumAllocationBytes: bound.maximumAllocationBytes,
            mosPreparationLimits: policy.preparationLimits,
            mosPreparationConditions: try .init(ambientKelvin: precise.settings.temperatureKelvin,
                nominalKelvin: precise.settings.nominalTemperatureKelvin, analysisCapabilities: [.dc, .transient]),
            diodePreparationLimits: policy.diodePreparationLimits, diodeAnalyses: [.dc, .transient])
        return (catalog, prepared, limits)
    }

    private func prepareNative(_ selected: Inputs.Case, catalog: URL, limits: SPICENativeExecutionLimits)
        async throws -> PreparedNativeSPICESimulation {
        let loaded = try CoreSpiceCLIOSDICatalog.load(path: catalog.path)
        let policy = try CoreSpiceCLIExecutionPolicy.developerV1().applying(loaded.executionBudget)
        let resources = try policy.resources()
        let binding = SPICEExactSourceBinding(key: "root", reference: try ArtifactReference(
            digest: .init(algorithm: .sha256, hexadecimalValue: selected.deck.sha256),
            byteCount: selected.deck.byteCount, descriptor: .init(role: .input, kind: .netlist, format: .spice)))
        let source: SPICECheckedSource
        do {
            let readReservation = try resources.reserveStorage(kind: .temporaryBytes, byteCount: 1024 * 1024)
            let bytes = try LocalSPICESourceReader().read(at: selected.deck.path,
                maximumByteCount: 1024 * 1024, maximumPageByteCount: 4096)
            let arrayReservation = try resources.reserveStorage(kind: .temporaryBytes, byteCount: UInt64(bytes.count))
            let array = Array(bytes)
            source = try SPICECheckedSource.admit(binding: binding, bytes: array.span,
                resources: resources, maximumPageByteCount: 4096)
            withExtendedLifetime((readReservation, arrayReservation)) {}
        }
        let parser = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "corespice-cli-prepared-v1",
            configuration: parser, resources: resources, maximumPageByteCount: 4096)
        let input = try await SPICESimulationPreparer().prepare(.init(root: source, environment: environment,
            catalog: [binding], routes: [], provider: NoDependencies(), configuration: parser,
            operatingPolicy: .recordActual,
            limits: .init(maximumElements: policy.maximumElements, maximumTransformBytes: policy.maximumTemporaryBytes,
                maximumSweepPoints: 1000, maximumPageByteCount: 4096, numerical: policy.numericalLimits),
            profile: policy.profile, seed: policy.seed, resolutionLimits: policy.resolutionLimits,
            diodeProfile: policy.diodeProfile, osdiInstances: loaded.instances), resources: resources)
        return try await SPICENativeSimulation().prepare(input, limits: limits, osdi: loaded.runtime)
    }

    private struct NoDependencies: SPICEExactSourceProviding {
        func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
                    maximumPageByteCount: UInt64) async throws -> SPICECheckedSource {
            throw SPICEExactSourceError.undeclaredSource(binding.key)
        }
    }

    private func check(_ execution: CoreSpiceCLIOSDIExecutionRecord, manifest: OSDIPrecisionManifest,
                       selected: Inputs.Case) throws {
        let precise = try #require(execution.precision)
        try #require(execution.analysis == "tran" && execution.coordinates.first == 0)
        try #require(execution.coordinates.last?.bitPattern == (2e-9 as Double).bitPattern)
        try #require(precise.settings.transient.stopTime.bitPattern == (2e-9 as Double).bitPattern)
        try #require(precise.settings.transient.maxTimeStep.bitPattern == (1e-10 as Double).bitPattern)
        try #require(execution.acceptedSteps.count == execution.coordinates.count - 1 && !execution.acceptedSteps.isEmpty)
        try #require(precise.solutionLow.count == execution.real.count)
        try #require(precise.solutionLow.contains { $0 != 0 })
        try #require(precise.highBits == execution.real.map(\.bitPattern) && precise.lowBits == precise.solutionLow.map(\.bitPattern))
        let capture = try #require(precise.sources.captures.first)
        try #require(precise.sources.captures.count == 1)
        try #require(capture.reference.digest.hexadecimalValue == selected.deck.sha256)
        try #require(capture.reference.byteCount == selected.deck.byteCount)
        try #require(precise.coldModels.count == 1)
        let cold = try #require(precise.coldModels.first)
        try #require(cold.workerReference.digest.hexadecimalValue == manifest.worker.sha256)
        try #require(cold.numericProfileSHA256 == manifest.numericProfileSHA256)
        try #require(cold.program.semanticProfileSHA256 == manifest.semanticProfileSHA256)
        try #require(cold.program.modelReference.digest.hexadecimalValue == manifest.models[0].sha256)
        try #require(cold.program.programSHA256 == manifest.models[0].program.sha256)
        try #require(cold.options == (try CoreSpiceCLIPrecisionOptions(manifest.options.value())) && cold.precisionBits == manifest.precisionBits)
        for row in precise.equationPolicy {
            let unit: String
            switch row.kind {
            case "electricalPotential": unit = "A"
            case "electricalFlow": unit = "V"
            case "thermalPotential": unit = "W"
            default: throw CLIError.state("Unexpected SOI equation kind")
            }
            try #require(row.equationAbsoluteTolerance == selected.input.circuit.policy.equationAbsoluteTolerances[unit])
        }
        for (index, step) in execution.acceptedSteps.enumerated() {
            let low = try #require(step.timeStepLowComponent)
            let actual = try CompensatedValue(high: execution.coordinates[index + 1])
                .subtracting(.init(high: execution.coordinates[index]))
            try #require(actual == (try CompensatedValue(high: step.timeStepSeconds, low: low)))
        }
    }

    private func persist<Value: Codable>(_ value: Value, to path: URL) throws -> Value {
        try JSONEncoder().encode(value).write(to: path, options: .withoutOverwriting)
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: path))
    }

    private func expectReleased(_ root: URL) throws {
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty,
            "Completed/refused execution must release staged model and worker owners")
    }

    private func checkPaired(_ path: URL, execution: CoreSpiceCLIOSDIExecutionRecord) throws {
        let precise = try #require(execution.precision)
        let limits = try CoreSpiceCLIPairedCSVCodec.Limits(maximumBytes: precise.executionBudget.maximumEvidenceBytes,
            maximumPoints: execution.coordinates.count, maximumColumns: execution.rows.count,
            maximumScalars: execution.real.count * 2 + execution.coordinates.count)
        let pair = try CoreSpiceCLIPairedCSVCodec.decode(Data(contentsOf: path), limits: limits)
        try #require(pair.configurationSHA256 == precise.configurationSHA256)
        try #require(pair.high.map(\.bitPattern) == precise.highBits && pair.low.map(\.bitPattern) == precise.lowBits)
        try #require(pair.times.map(\.bitPattern) == precise.coordinateBits)
        try #require(pair.compiledRows == Array(execution.rows.indices))
    }

    private enum HarnessFailure: Error {
        case persistence(primary: TimedProcessError, reason: String)
    }

    private func process(_ arguments: [String], output: URL, maximumOutputBytes: UInt64) async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_CLI_EXECUTABLE"])
        let text = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_SOI101_TIMEOUT_SECONDS"])
        let seconds = try #require(UInt32(text)); try #require(seconds > 0 && seconds <= 3600)
        let runner = TimedProcessRunner(timeoutSeconds: Double(seconds),
            maximumOutputByteCount: maximumOutputBytes, cleanupTimeoutSeconds: 2)
        let control = TimedProcessControl()
        let result: TimedProcessResult
        do {
            result = try await runner.run(executableURL: URL(fileURLWithPath: executable),
                arguments: arguments, control: control)
        } catch TimedProcessError.executionFailed(let original) {
            var failure = original
            if let handle = original.cleanupHandle {
                do {
                    try await handle.close(timeoutSeconds: 2)
                    failure = TimedProcessFailure(executablePath: original.executablePath, cause: original.cause,
                        standardOutputData: original.standardOutputData, standardErrorData: original.standardErrorData)
                } catch {
                    failure = TimedProcessFailure(executablePath: original.executablePath, cause: original.cause,
                        standardOutputData: original.standardOutputData, standardErrorData: original.standardErrorData,
                        cleanupIssue: "\(original.cleanupIssue ?? "pending"); retry: \(error)", cleanupHandle: handle)
                }
            }
            let primary = TimedProcessError.executionFailed(failure)
            do {
                try failure.standardOutputData.write(to: output, options: .withoutOverwriting)
                try failure.standardErrorData.write(to: output.appendingPathExtension("stderr"), options: .withoutOverwriting)
            } catch { throw HarnessFailure.persistence(primary: primary, reason: String(describing: error)) }
            throw primary
        }
        try result.standardOutputData.write(to: output, options: .withoutOverwriting)
        try result.standardErrorData.write(to: output.appendingPathExtension("stderr"), options: .withoutOverwriting)
        try #require(result.exitCode == 0, "Latest SOI CLI failed: \(result.standardError); output \(output.path)")
    }

    private func refuseExhaustedWorker(_ selected: Inputs.Case, catalog: URL) async throws {
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        var precise = try #require(json["transientPrecision"] as? [String: Any])
        var options = try #require(precise["options"] as? [String: Any])
        options["maximumWorkUnits"] = 1; precise["options"] = options; json["transientPrecision"] = precise
        let root = URL(fileURLWithPath: selected.directory)
        let failedCatalog = root.appendingPathComponent("exhausted-catalog.json")
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: failedCatalog, options: .withoutOverwriting)
        let csv = root.appendingPathComponent("refused.csv"), pair = root.appendingPathComponent("refused-paired.csv")
        let command = CoreSpicePreparedCommand(arguments: [selected.deck.path, "--osdi-catalog", failedCatalog.path,
            "--csv", csv.path, "--paired-csv", pair.path])
        do {
            _ = try await command.executeWithRecord()
            Issue.record("Exhausted latest SOI worker published completion")
        } catch SPICENativeExecutionError.osdi(.runtime(.precision(let issue))) {
            #expect(issue.code == .numericFailure && issue.workerStatus == 7)
            #expect(!FileManager.default.fileExists(atPath: csv.path) && !FileManager.default.fileExists(atPath: pair.path))
        }
        try expectReleased(root)
    }

    private func object<Value: Encodable>(_ value: Value) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func makeCatalog(_ selected: Inputs.Case, manifest: OSDIPrecisionManifest) async throws -> URL {
        let root = URL(fileURLWithPath: selected.directory, isDirectory: true)
        try #require(manifest.models.count == 1 && manifest.models[0].id == "soi101")
        let model = try #require(manifest.models.first), device = try #require(selected.input.circuit.devices.first)
        let image = URL(fileURLWithPath: model.path), worker = URL(fileURLWithPath: manifest.worker.path)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let reference = try ArtifactReference(digest: .init(algorithm: .sha256, hexadecimalValue: model.sha256),
            byteCount: model.byteCount, descriptor: .init(role: .input, kind: .model, format: .unknown))
        let workerReference = try ArtifactReference(digest: .init(algorithm: .sha256, hexadecimalValue: manifest.worker.sha256),
            byteCount: manifest.worker.byteCount, descriptor: .init(role: .input, kind: .other, format: .raw))
        func access(_ bytes: UInt64) -> [String: UInt64] {
            ["maximumPageByteCount": min(bytes, 65536), "maximumTotalByteCount": bytes, "maximumPageCount": 65536,
             "maximumWorkUnitCount": 65536, "maximumDurationNanoseconds": 10_000_000_000]
        }
        let assignments = try device.parameters.map { try $0.assignment() }
        var catalog: [String: Any] = ["schemaVersion": 1, "libraryRootPath": image.deletingLastPathComponent().path,
            "stagingParentDirectory": staging.path,
            "artifacts": [["reference": try object(reference), "relativePath": [image.lastPathComponent], "accessBudget": access(model.byteCount)]],
            "instances": [["instanceName": "n_m1", "modelName": "M1", "artifact": try object(reference),
                "descriptorIndex": model.descriptorIndex, "expectedDescriptorName": model.descriptorName,
                "modelParameters": try assignments.filter { $0.scope == .model }.map { try object(CoreSpiceCLIOSDIParameterRecord($0)) },
                "instanceParameters": try assignments.filter { $0.scope == .instance }.map { try object(CoreSpiceCLIOSDIParameterRecord($0)) }, "previousState": device.previousState]],
            "loadLimits": ["maximumDescriptors": 16, "maximumMetadataBytes": 4 * 1024 * 1024, "maximumStorageBytes": 4 * 1024 * 1024],
            "evaluationLimits": ["maximumWorkspaceBytes": 8 * 1024 * 1024, "maximumDiagnosticCount": 256,
                "maximumDiagnosticBytes": 65536, "maximumStringBytes": 65536],
            "maximumInstanceCount": 16, "maximumAdapterBytes": 8 * 1024 * 1024,
            "tolerances": ["temperatureAbsoluteKelvin": try #require(selected.input.circuit.policy.unknownAbsoluteTolerances["K"]), "thermalResidualAbsoluteWatts": 1e-12]]
        let metadata = root.appendingPathComponent("metadata-catalog.json")
        try JSONSerialization.data(withJSONObject: catalog).write(to: metadata, options: .withoutOverwriting)
        let ordinary = try CoreSpiceCLIOSDICatalog.load(path: metadata.path)
        let library = try await ordinary.runtime.provider.load(reference: reference, limits: ordinary.runtime.loadLimits)
        let count: Int
        do { count = try #require(library.descriptors.first { Int($0.index) == model.descriptorIndex }).nodeCount }
        catch { try library.close(); throw error }
        try library.close()
        let options = try manifest.options.value()
        let extra = try OSDIAdapterCapacity.precision(nodeCount: count, options: options)
        let workerBytes = options.arenaBytes + options.maximumMappingBytes
        catalog["schemaVersion"] = 2
        catalog["maximumAdapterBytes"] = 8 * 1024 * 1024 + extra
        catalog["executionBudget"] = ["maximumNativeAllocationBytes": 64 * 1024 * 1024 + workerBytes + extra,
            "maximumLiveOwnedBytes": 2 * (128 * 1024 * 1024 + workerBytes + extra),
            "maximumTemporaryBytes": 128 * 1024 * 1024, "maximumHashedBytes": 64 * 1024 * 1024,
            "maximumEvidenceBytes": 128 * 1024 * 1024]
        catalog["transientPrecision"] = ["workerRootPath": worker.deletingLastPathComponent().path,
            "worker": ["reference": try object(workerReference), "relativePath": [worker.lastPathComponent], "accessBudget": access(manifest.worker.byteCount)],
            "semanticProfileSHA256": manifest.semanticProfileSHA256, "numericProfileSHA256": manifest.numericProfileSHA256,
            "precisionBits": manifest.precisionBits, "options": try JSONSerialization.jsonObject(with: JSONEncoder().encode(CoreSpiceCLIPrecisionOptions(options)))]
        let path = root.appendingPathComponent("catalog.json")
        try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys]).write(to: path, options: .withoutOverwriting)
        return path
    }
}

import CircuiteFoundation
import CircuiteFoundationFoundation
import CoreSpice
import CoreSpiceExporterCSV
import CoreSpiceOSDITestSupport
import CoreSpiceWaveform
import Darwin
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite("OSDI CLI actual execution", .timeLimit(.minutes(3)))
struct OSDICLIExecutionTests {
    struct Fixture {
        let root: URL
        let deck: URL
        let catalog: URL
        let csv: URL
        let json: [String: Any]
    }
    func manifest() throws -> OSDIDCManifest {
        let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_DC_MANIFEST"])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let profile = ProcessInfo.processInfo.environment["CORESPICE_OSDI_DC_PROFILE"] ?? "latest-soi101-v1"
        try OSDIFamilyProfileAdmission.validate(bytes, profile: profile)
        return try JSONDecoder().decode(OSDIDCManifest.self, from: bytes)
    }
    func fixture(_ point: OSDIDCManifest.Case, manifest: OSDIDCManifest, terminalNames: [String: [String]] = [:]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("osdi-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let deck = root.appendingPathComponent("input.cir"), catalog = root.appendingPathComponent("catalog.json")
        var lines = ["explicit OSDI CLI \(point.id)"]
        let temperature = try #require(point.input.devices.first).temperatureKelvin
        #expect(point.input.devices.allSatisfy { $0.temperatureKelvin == temperature })
        lines.append(".temp \(temperature - 273.15)")
        let policy = point.input.policy
        lines.append(".options reltol=\(policy.relativeTolerance) vntol=\(try #require(policy.unknownAbsoluteTolerances["V"])) abstol=\(try #require(policy.equationAbsoluteTolerances["A"])) itl1=\(policy.maximumIterations) gmin=0")
        var artifacts: [[String: Any]] = [], entries: [[String: Any]] = []
        var references: [String: ArtifactReference] = [:]
        for device in point.input.devices {
            let library = try #require(manifest.libraries.first { $0.id == device.library })
            if references[library.id] == nil {
                let destination = root.appendingPathComponent(library.id + ".osdi")
                try FileManager.default.copyItem(atPath: library.path, toPath: destination.path)
                let size = try #require(FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber).uint64Value
                let reference = try ArtifactReference(digest: .init(algorithm: .sha256, hexadecimalValue: library.sha256),
                    byteCount: size, descriptor: .init(role: .input, kind: .model, format: .unknown))
                references[library.id] = reference
                artifacts.append(["reference": try object(reference), "relativePath": [destination.lastPathComponent],
                    "accessBudget": ["maximumPageByteCount": 65536, "maximumTotalByteCount": max(size, 65536),
                        "maximumPageCount": 16384, "maximumWorkUnitCount": 32768, "maximumDurationNanoseconds": 10_000_000_000]])
            }
            let reference = try #require(references[library.id])
            let terminals: [String]
            if let names = terminalNames[device.id] { terminals = try names.map { try #require(device.terminals[$0]) } }
            else {
                let raw = try #require(point.reference.devices.first { $0.id == device.id }).rawNodes
                terminals = try (0..<device.connectedTerminalCount).map { try #require(device.terminals[raw[$0].name]) }
            }
            let symbol = "model_" + device.id.lowercased()
            lines.append(".model \(symbol) osdi")
            let sourceName = "N_" + device.id
            lines.append(([sourceName] + terminals + [symbol]).joined(separator: " "))
            let assignments = try device.parameters.map { try $0.assignment() }
            entries.append(["instanceName": sourceName.lowercased(), "modelName": symbol,
                "artifact": try object(reference), "descriptorIndex": device.descriptorIndex,
                "expectedDescriptorName": library.descriptorName,
                "modelParameters": try assignments.filter { $0.scope == .model }.map { try object(CoreSpiceCLIOSDIParameterRecord($0)) },
                "instanceParameters": try assignments.filter { $0.scope == .instance }.map { try object(CoreSpiceCLIOSDIParameterRecord($0)) },
                "previousState": device.previousState])
        }
        for part in point.input.resistors + point.input.voltageSources + point.input.currentSources {
            lines.append("\(part.id) \(part.positive) \(part.negative) \(part.value)")
        }
        for (name, value) in point.input.initialUnknowns.sorted(by: { $0.key < $1.key }) where name.hasPrefix("net:") {
            lines.append(".nodeset V(\(name.dropFirst(4)))=\(value)")
        }
        lines += [".op", ".end", ""]
        try lines.joined(separator: "\n").write(to: deck, atomically: true, encoding: .utf8)
        let json: [String: Any] = ["schemaVersion": 1, "libraryRootPath": root.path,
            "stagingParentDirectory": root.path, "artifacts": artifacts, "instances": entries,
            "loadLimits": ["maximumDescriptors": 16, "maximumMetadataBytes": 4 * 1024 * 1024, "maximumStorageBytes": 4 * 1024 * 1024],
            "evaluationLimits": ["maximumWorkspaceBytes": 8 * 1024 * 1024, "maximumDiagnosticCount": 256,
                "maximumDiagnosticBytes": 65536, "maximumStringBytes": 65536],
            "maximumInstanceCount": 16, "maximumAdapterBytes": 8 * 1024 * 1024,
            "tolerances": ["temperatureAbsoluteKelvin": try #require(policy.unknownAbsoluteTolerances["K"]),
                "thermalResidualAbsoluteWatts": try #require(policy.equationAbsoluteTolerances["W"])]]
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: catalog)
        return Fixture(root: root, deck: deck, catalog: catalog, csv: root.appendingPathComponent("waveform.csv"), json: json)
    }
    func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    func cleanup(_ fixture: Fixture) {
        do { try FileManager.default.removeItem(at: fixture.root) } catch { Issue.record("Fixture cleanup failed: \(error)") }
    }
    func validate(_ point: OSDIDCManifest.Case, models: [CoreSpiceCLIOSDIRecord],
                          variables: [CoreSpiceCLIOSDIVariableRecord], waveform: WaveformData) async throws {
        #expect(waveform.pointCount == 1 && variables.count == waveform.variables.count)
        #expect(variables.map(\.row).sorted() == Array(0..<variables.count))
        var candidates: [String: Double] = [:], joinedRows = Set<Int>()
        var nets = Set<String>()
        for device in point.input.devices { nets.formUnion(device.terminals.values) }
        for part in point.input.resistors + point.input.voltageSources + point.input.currentSources { nets.insert(part.positive); nets.insert(part.negative) }
        for variable in variables {
            if let name = variable.sourceName {
                if variable.kind == "node", let net = nets.first(where: { $0.lowercased() == name }) {
                    candidates["net:" + net] = variable.value; joinedRows.insert(variable.row)
                } else if variable.kind == "branch", let source = point.input.voltageSources.first(where: { $0.id.lowercased() == name }) {
                    candidates["branch:" + source.id] = variable.value; joinedRows.insert(variable.row)
                }
            }
            let exported = try #require(waveform.realValue(variable: variable.row, point: 0))
            // CSV developer defaults retain 15 significant digits; canonical JSON rows retain the exact Double.
            let exportTolerance = max(abs(variable.value) * 8e-15, Double.leastNonzeroMagnitude)
            #expect(abs(exported - variable.value) <= exportTolerance)
            #expect(waveform.variables[variable.row].unit.rawValue == variable.unit)
            if variable.unit == "K" { #expect(waveform.variables[variable.row].name.hasPrefix("dT(")) }
        }
        #expect(models.count == point.input.devices.count)
        for model in models {
            let device = try #require(point.input.devices.first { ("n_" + $0.id.lowercased()) == model.instanceName })
            let raw = try #require(point.reference.devices.first { $0.id == device.id }).rawNodes
            #expect(model.effectiveKelvin == device.temperatureKelvin && model.previousState == device.previousState)
            #expect(model.rawNodeGlobalRows.count == raw.count)
            for node in raw {
                #expect(model.rawNodeNames[node.index] == node.name)
                #expect(model.rawNodeUnits[node.index] == node.unit && model.rawEquationUnits[node.index] == node.residualUnit)
                if let id = node.unknownID {
                    let row = try #require(model.rawNodeGlobalRows[node.index])
                    let value = variables[row].value
                    if let existing = candidates[id] { #expect(existing == value) }
                    candidates[id] = value; joinedRows.insert(row)
                }
            }
            let expectedModels: [CoreSpiceCLIOSDIParameterRecord] = try device.parameters.filter { $0.scope == "model" }.map { CoreSpiceCLIOSDIParameterRecord(try $0.assignment()) }
            let expectedInstances: [CoreSpiceCLIOSDIParameterRecord] = try device.parameters.filter { $0.scope == "instance" }.map { CoreSpiceCLIOSDIParameterRecord(try $0.assignment()) }
            #expect(model.modelParameters == expectedModels)
            #expect(model.instanceParameters == expectedInstances)
        }
        let reference = try #require(point.reference.unknowns)
        #expect(candidates.count == reference.count && joinedRows.count == variables.count)
        for unknown in reference {
            let value = try #require(candidates[unknown.id])
            let tolerance = try #require(point.input.policy.unknownAbsoluteTolerances[unknown.unit]) + point.input.policy.relativeTolerance * abs(unknown.value)
            #expect(abs(value - unknown.value) <= tolerance, "\(point.id):\(unknown.id)")
        }
        var arguments = Array(point.validationBaseCommand.dropFirst())
        for name in candidates.keys.sorted() { arguments += ["--candidate", name, String(try #require(candidates[name]))] }
        let result = try await process(executable: #require(point.validationBaseCommand.first), arguments: arguments)
        #expect(result.status == 0, "\(point.id) physical residual: \(result.text)")
    }
    func process(executable: String, arguments: [String]) async throws -> (status: Int32, text: String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.filter { ["HOME", "PATH", "TMPDIR", "SDKROOT", "TOOLCHAINS", "MallocNanoZone"].contains($0.key) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("osdi-cli-process-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw OSDIDCManifest.Failure.invalidManifest }
        let handle = try FileHandle(forWritingTo: output)
        defer { handle.closeFile(); do { try FileManager.default.removeItem(at: output) } catch { Issue.record("Process output cleanup failed") } }
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while process.isRunning {
            if ContinuousClock.now >= deadline {
                kill(process.processIdentifier, SIGKILL)
                throw OSDIDCManifest.Failure.oracleFailure("bounded subprocess timeout")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return (process.terminationStatus, String(decoding: try Data(contentsOf: output), as: UTF8.self))
    }

    @Test func originalBatchAllCasesSaveReloadAndIndependentPhysicalResidual() async throws {
        let manifest = try manifest()
        #expect(manifest.cases.count >= 43)
        for point in manifest.cases {
            let fixture = try fixture(point, manifest: manifest); defer { cleanup(fixture) }
            let arguments = ["-b", fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path, "--json"]
            var session = try Session(policy: .developerV1())
            do {
                let record = try await CLI(arguments: arguments).executeBatch(options: .init(arguments: arguments), session: &session)
                #expect(point.reference.status == "converged", "\(point.id) unexpectedly succeeded")
                let saved = fixture.root.appendingPathComponent("execution.json")
                try JSONEncoder().encode(record).write(to: saved)
                let reloaded = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: Data(contentsOf: saved))
                let waveform = try CSVWaveformReader().read(contentsOfFile: fixture.csv.path)
                try await validate(point, models: #require(reloaded.osdiModels), variables: #require(reloaded.osdiVariables), waveform: waveform)
                let referencer = try CoreSpiceCLIArtifactReferencer()
                var expectedInputs = Set([try referencer.input(path: fixture.deck.path, kind: .netlist, format: .spice),
                    try referencer.input(path: fixture.catalog.path, kind: .model, format: .json)])
                let artifacts = try #require(fixture.json["artifacts"] as? [[String: Any]])
                for artifact in artifacts {
                    let reference = try JSONDecoder().decode(ArtifactReference.self,
                        from: JSONSerialization.data(withJSONObject: try #require(artifact["reference"])))
                    expectedInputs.insert(reference)
                }
                #expect(Set(reloaded.inputArtifacts) == expectedInputs)
                print("OSDI CLI batch \(point.id): saved/reloaded all \(waveform.variables.count) coordinates validated")
            } catch {
                guard point.reference.status != "converged" else { throw error }
                let failure = CoreSpiceCLIFailure(error: error)
                #expect(["analysis.singular-matrix", "analysis.convergence-failure"].contains(failure.code), "\(point.id): \(failure.code)")
                #expect(!FileManager.default.fileExists(atPath: fixture.csv.path))
                #expect(session.completedOSDIModels.isEmpty)
            }
        }
    }

    @Test func preparedPathAndRetainedRerunPreserveBindingsAndThermalWaveform() async throws {
        let manifest = try manifest()
        let profile = ProcessInfo.processInfo.environment["CORESPICE_OSDI_DC_PROFILE"] ?? "latest-soi101-v1"
        let selected = try OSDIFamilyProfileAdmission.cliRepresentativeCaseIDs(profile: profile, prepared: true)
        for id in selected {
            let point = try #require(manifest.cases.first { $0.id == id })
            let fixture = try fixture(point, manifest: manifest); defer { cleanup(fixture) }
            var output: SPICENativeSimulationOutput? = try await CoreSpicePreparedCommand(arguments: [fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path]).execute()
            let record = try CoreSpiceCLIPreparedRunRecord(#require(output))
            let saved = fixture.root.appendingPathComponent("prepared.json")
            try JSONEncoder().encode(record).write(to: saved)
            let reloaded = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(contentsOf: saved))
            let waveform = try CSVWaveformReader().read(contentsOfFile: fixture.csv.path)
            try await validate(point, models: #require(reloaded.osdiModels), variables: #require(reloaded.osdiVariables), waveform: waveform)
            let retainedInput = try #require(output?.prepared.input)
            let retainedLimits = try #require(output?.prepared.limits)
            let retainedRuntime = try #require(output?.prepared.osdiRuntimeInputs)
            let expectedIdentity = try #require(output?.configurationIdentity)
            output = nil
            let native = SPICENativeSimulation()
            let prepared = try await native.prepare(retainedInput, limits: retainedLimits, osdi: retainedRuntime)
            let rerun = try await native.execute(prepared, cancellation: .init())
            #expect(rerun.configurationIdentity == expectedIdentity)
            let repeated = try CoreSpiceCLIPreparedRunRecord(rerun)
            #expect(repeated.osdiModels == reloaded.osdiModels && repeated.osdiVariables == reloaded.osdiVariables)
        }
    }

    @Test func selectedAndReorderedCSVRetainsCompleteCanonicalRowValues() async throws {
        let manifest = try manifest(), point = try #require(manifest.cases.first { $0.id == "linear-current" })
        for selection in [".save I(VREF) V(p)", ".print op I(VREF) V(n) V(p)"] {
            let fixture = try fixture(point, manifest: manifest); defer { cleanup(fixture) }
            let source = try String(contentsOf: fixture.deck, encoding: .utf8).replacingOccurrences(of: ".op\n", with: ".op\n" + selection + "\n")
            try source.write(to: fixture.deck, atomically: true, encoding: .utf8)
            let arguments = ["-b", fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path, "--json"]
            var session = try Session(policy: .developerV1())
            let completed = try await CLI(arguments: arguments).executeBatch(options: .init(arguments: arguments), session: &session)
            let saved = fixture.root.appendingPathComponent("selected.json")
            try JSONEncoder().encode(completed).write(to: saved)
            let record = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: Data(contentsOf: saved))
            let rows = try #require(record.osdiVariables), models = try #require(record.osdiModels)
            #expect(rows.count == 3)
            for corruption in ["missing-value", "invalid-value", "duplicate-row", "missing-rows", "model-schema"] {
                var invalid = try #require(object(record) as? [String: Any])
                var encodedRows = try #require(invalid["osdiVariables"] as? [[String: Any]])
                switch corruption {
                case "missing-value": encodedRows[0].removeValue(forKey: "value")
                case "invalid-value": encodedRows[0]["value"] = "NaN"
                case "duplicate-row": encodedRows[1]["row"] = 0
                case "missing-rows": invalid.removeValue(forKey: "osdiVariables")
                case "model-schema":
                    var encodedModels = try #require(invalid["osdiModels"] as? [[String: Any]])
                    encodedModels[0]["schemaVersion"] = 99; invalid["osdiModels"] = encodedModels
                default: Issue.record("Unknown saved-record corruption")
                }
                if corruption != "missing-rows" { invalid["osdiVariables"] = encodedRows }
                let bytes = try JSONSerialization.data(withJSONObject: invalid)
                do { _ = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: bytes); Issue.record("Invalid saved \(corruption) decoded") }
                catch { #expect(error is DecodingError || error is CoreSpiceCLIOSDIError) }
            }
            let csv = try CSVWaveformReader().read(contentsOfFile: fixture.csv.path)
            let requested = selection.hasPrefix(".save") ? ["I(vref)", "V(p)"] : ["I(vref)", "V(n)", "V(p)"]
            #expect(csv.variables.map(\.name) == requested)
            let values = ["V(p)": 0.3, "V(n)": 0.2, "I(vref)": 0.0001]
            for (column, name) in requested.enumerated() {
                let expected = try #require(values[name]), actual = try #require(csv.realValue(variable: column, point: 0))
                #expect(abs(actual - expected) < 1e-12)
            }
            let model = try #require(models.first)
            let raw = try #require(point.reference.devices.first).rawNodes
            var candidates: [String: Double] = [:]
            for node in raw {
                if let id = node.unknownID { candidates[id] = rows[try #require(model.rawNodeGlobalRows[node.index])].value }
            }
            let sourceRow = try #require(rows.first { $0.kind == "branch" && $0.sourceName == "vref" })
            candidates["branch:VREF"] = sourceRow.value
            #expect(candidates.count == rows.count)
            var oracleArguments = Array(point.validationBaseCommand.dropFirst())
            for name in candidates.keys.sorted() { oracleArguments += ["--candidate", name, String(try #require(candidates[name]))] }
            let result = try await process(executable: #require(point.validationBaseCommand.first), arguments: oracleArguments)
            #expect(result.status == 0)
        }
    }

    @Test func catalogsTypesIdentityAndUnsupportedAnalysisPublishNoCompletedWaveform() async throws {
        let manifest = try manifest(), point = try #require(manifest.cases.first { $0.id == "linear-current" })
        for mutation in ["schema", "descriptor", "descriptor-index", "kind", "json-kind", "unknown-zero", "scope", "budget", "digest", "analysis", "catalog-key"] {
            let fixture = try fixture(point, manifest: manifest); defer { cleanup(fixture) }
            var json = fixture.json
            var entries = try #require(json["instances"] as? [[String: Any]])
            switch mutation {
            case "schema": json["schemaVersion"] = 99
            case "descriptor": entries[0]["expectedDescriptorName"] = "wrong"
            case "descriptor-index": entries[0]["descriptorIndex"] = 999
            case "kind": entries[0]["instanceParameters"] = [["name": "g", "scope": "instance", "type": "string", "value": "wrong"]]
            case "json-kind": entries[0]["instanceParameters"] = [["name": "g", "scope": "instance", "type": "real", "value": "wrong"]]
            case "unknown-zero": entries[0]["instanceParameters"] = [["name": "unknown", "scope": "instance", "type": "real", "value": 0]]
            case "scope": entries[0]["instanceParameters"] = [["name": "g", "scope": "model", "type": "real", "value": 1]]
            case "budget": json["loadLimits"] = ["maximumDescriptors": 0, "maximumMetadataBytes": 1, "maximumStorageBytes": 1]
            case "catalog-key": entries[0]["instanceName"] = "typo"
            case "digest":
                let path = fixture.root.appendingPathComponent("linear_dc.osdi")
                let handle = try FileHandle(forWritingTo: path); try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
            case "analysis":
                let text = try String(contentsOf: fixture.deck, encoding: .utf8).replacingOccurrences(of: ".op\n", with: ".dc VREF 0.1 0.2 0.1 VREF 0.1 0.2 0.1\n")
                try text.write(to: fixture.deck, atomically: true, encoding: .utf8)
            default: Issue.record("Unknown fixture mutation")
            }
            json["instances"] = entries
            try JSONSerialization.data(withJSONObject: json).write(to: fixture.catalog)
            let arguments = ["-b", fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path, "--json"]
            var session = try Session(policy: .developerV1())
            do {
                _ = try await CLI(arguments: arguments).executeBatch(options: .init(arguments: arguments), session: &session)
                Issue.record("Invalid \(mutation) completed")
            } catch {
                let code = CoreSpiceCLIFailure(error: error).code
                #expect(mutation == "analysis" ? code == "osdi.unsupported-analysis"
                    : code.hasPrefix("osdi.") || code == "lowering.osdi_input", "\(mutation): \(code)")
                #expect(session.completedOSDIModels.isEmpty)
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.csv.path))
            do { _ = try await CoreSpicePreparedCommand(arguments: [fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path]).execute(); Issue.record("Invalid prepared \(mutation) completed") }
            catch {
                let code = CoreSpiceCLIFailure(error: error).code
                #expect(mutation == "analysis" ? code == "preparation.unsupported-capability"
                    : code.hasPrefix("osdi.") || code == "lowering.osdi_input" || code == "preparation.unsupported-capability", "prepared \(mutation): \(code)")
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.csv.path))
        }
    }

    @Test func actualExecutableAllAvailableFamiliesAndJSONFailureExit() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_CLI_EXECUTABLE"])
        let manifest = try manifest()
        let profile = ProcessInfo.processInfo.environment["CORESPICE_OSDI_DC_PROFILE"] ?? "latest-soi101-v1"
        let selected = try OSDIFamilyProfileAdmission.cliRepresentativeCaseIDs(profile: profile, prepared: false)
        for id in selected {
            let point = try #require(manifest.cases.first { $0.id == id })
            let fixture = try fixture(point, manifest: manifest); defer { cleanup(fixture) }
            let arguments = ["-b", fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path, "--json"]
            let success = try await process(executable: executable, arguments: arguments)
            #expect(success.status == 0, "\(success.text)")
            let record = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: Data(success.text.utf8))
            try await validate(point, models: #require(record.osdiModels), variables: #require(record.osdiVariables),
                waveform: CSVWaveformReader().read(contentsOfFile: fixture.csv.path))
            try FileManager.default.removeItem(at: fixture.csv)
            var invalid = fixture.json; invalid["schemaVersion"] = 99
            try JSONSerialization.data(withJSONObject: invalid).write(to: fixture.catalog)
            let failure = try await process(executable: executable, arguments: arguments)
            #expect(failure.status == 2)
            let recordFailure = try JSONDecoder().decode(CoreSpiceCLIFailure.self, from: Data(failure.text.utf8))
            #expect(recordFailure.status == "failed" && recordFailure.code == "osdi.catalog")
            #expect(!FileManager.default.fileExists(atPath: fixture.csv.path))
        }
    }
}

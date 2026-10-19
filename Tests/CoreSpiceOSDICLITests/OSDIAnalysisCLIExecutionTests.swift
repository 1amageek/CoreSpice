import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceEvent
import CoreSpiceIO
import CoreSpiceExporterCSV
import CoreSpiceOSDITestSupport
import CoreSpiceWaveform
import Foundation
import OSDIRuntime
import Testing
@testable import CoreSpiceCLICore

@Suite("OSDI ordinary AC, noise and analytic transient CLI evidence", .timeLimit(.minutes(5)))
struct OSDIAnalysisCLIExecutionTests {
    private let helper = OSDICLIExecutionTests()
    @Test func latestSOI101ACAndNoiseBatchPreparedExecutableSaveReloadAndIndependentCandidate() async throws {
        let input = try input(latestSOI101: true)
        let executable = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_CLI_EXECUTABLE"])
        let points = input.manifest.cases.filter { $0.kind == "ac" || $0.kind == "noise" }
        try #require(points.count == 2 && Set(points.map(\.id)) == ["soi101-ac", "soi101-noise"])
        for point in points {
            try #require(point.input.analysis.frequenciesHz == [1e3, 1e4, 1e5, 1e6])
            try await replayBatchPrepared(point, input: input)
            try await replayExecutable(point, input: input, executable: executable)
        }
    }

    private static let realTransientPrecisionOwners = [
        "bsim-n-loaded-s4-transient": "fullBulkNLoaded",
        "bsim-p-reverse-loaded-s4-transient": "fullBulkPReverseLoaded",
        "bsim-p-selfheat-loaded-s4-transient": "fullBulkPSelfheatLoaded",
        "cmg-n-loaded-s4-transient": "fullCMGNLoaded",
        "cmg-p-reverse-loaded-s4-transient": "fullCMGPReverseLoaded",
        "cmg-n-selfheat-series-loaded-s4-transient": "fullCMGNSelfheatSeriesLoaded",
        "img-n-loaded-s4-transient": "fullIMGNLoaded",
        "img-p-reverse-s4-transient": "fullIMGPReverse",
        "img-n-thermal-s4-transient": "fullIMGNThermal",
        "soi-n-forward-s4-transient": "fullSOINForward",
        "soi-p-reverse-s4-transient": "fullSOIPReverse",
        "soi-n-series-thermal-s4-transient": "fullSOINSeriesThermal"
    ]
    private func usesOrdinaryWitness(_ point: OSDIAnalysisManifest.Case) -> Bool {
        point.family == nil || point.kind != "transient"
    }
    private struct Input {
        let manifest: OSDIAnalysisManifest
        let raw: [String: Any]
        let dc: OSDIDCManifest
    }
    private func input(latestSOI101: Bool = false) throws -> Input {
        let key = latestSOI101 ? "CORESPICE_OSDI_SOI101_ANALYSIS_MANIFEST" : "CORESPICE_OSDI_ANALYSIS_MANIFEST"
        let path = try #require(ProcessInfo.processInfo.environment[key])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        if latestSOI101 { try OSDIFamilyProfileAdmission.validateLatestSOI101Analysis(bytes) }
        let raw = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let dc = try JSONDecoder().decode(OSDIDCManifest.self, from: JSONSerialization.data(withJSONObject: ["libraries": try #require(raw["libraries"]), "cases": []]))
        return .init(manifest: try JSONDecoder().decode(OSDIAnalysisManifest.self, from: bytes), raw: raw, dc: dc)
    }
    private func fixture(_ point: OSDIAnalysisManifest.Case, input: Input) async throws -> OSDICLIExecutionTests.Fixture {
        let cases = try #require(input.raw["cases"] as? [[String: Any]])
        let raw = try #require(cases.first { $0["id"] as? String == point.id })
        let request = try #require(raw["input"] as? [String: Any])
        let converted: [String: Any] = ["id": point.id, "input": try #require(request["circuit"]),
            "reference": ["status": "converged", "devices": []], "validationBaseCommand": []]
        let dcCase = try JSONDecoder().decode(OSDIDCManifest.Case.self, from: JSONSerialization.data(withJSONObject: converted))
        var ordered: [String: [String]] = [:]
        for device in point.input.circuit.devices {
            ordered[device.id] = try await preparedTerminalNames(device, input: input)
        }
        let fixture = try helper.fixture(dcCase, manifest: input.dc, terminalNames: ordered)
        do {
            var source = try String(contentsOf: fixture.deck, encoding: .utf8)
            let policy = point.input.circuit.policy
            let options = ".options reltol=\(policy.relativeTolerance) vntol=\(try #require(policy.equationAbsoluteTolerances["V"])) abstol=\(try #require(policy.equationAbsoluteTolerances["A"])) itl1=\(policy.maximumIterations) gmin=0 tnom=27 tranmaxaccepted=1000 tranmaxattempts=10000 tranmaxiterations=100000 tranmaxscalars=100000 tranmaxdimension=256 tranmaxwork=1000000000 tranmaxbreakpoints=100"
            source = source.components(separatedBy: "\n").map { $0.hasPrefix(".options ") ? options : $0 }.joined(separator: "\n")
            let analysis = point.input.analysis
            if let stimulus = analysis.stimulus {
                source = try source.components(separatedBy: "\n").map { line in
                    guard line.hasPrefix(stimulus.sourceID + " ") else { return line }
                    if point.kind == "transient" {
                        let points = try #require(stimulus.points)
                        let part = try #require((point.input.circuit.voltageSources + point.input.circuit.currentSources).first { $0.id == stimulus.sourceID })
                        let first = try #require(points.first)
                        try #require(first.timeSeconds == 0 && first.value == part.value)
                        let prefix = "\(part.id) \(part.positive) \(part.negative) "
                        if points.count == 1 { return prefix + String(first.value) }
                        return prefix + "PWL(" + points.map { "\($0.timeSeconds) \($0.value)" }.joined(separator: " ") + ")"
                    }
                    let real = stimulus.real ?? 1, imag = stimulus.imag ?? 0
                    return line + " AC \(hypot(real, imag)) acphase=\(atan2(imag, real) * 180 / .pi)"
                }.joined(separator: "\n")
            }
            let command: String
            switch point.kind {
            case "ac":
                let endpoints = try OSDIFamilyProfileAdmission.decadeSweepEndpoints(#require(analysis.frequenciesHz))
                command = ".ac dec 1 \(endpoints.first) \(endpoints.last)"
            case "noise":
                let output = try #require(analysis.output)
                func net(_ id: String?) throws -> String {
                    guard let id, id != "0" else { return "0" }
                    guard id.hasPrefix("net:") else { throw OSDIDCManifest.Failure.invalidManifest }; return String(id.dropFirst(4))
                }
                let positive = try net(output.positiveUnknownID)
                let outputText: String
                if let reference = output.negativeUnknownID, reference != "0" { outputText = positive + "," + (try net(reference)) }
                else { outputText = positive }
                let endpoints = try OSDIFamilyProfileAdmission.decadeSweepEndpoints(#require(analysis.frequenciesHz))
                command = ".noise V(\(outputText)) \(try #require(analysis.inputSourceID)) dec 1 \(endpoints.first) \(endpoints.last)"
            case "transient":
                let steps = try #require(analysis.steps)
                command = ".tran \(try #require(steps.first).timeStepSeconds) \(try #require(steps.last).timeSeconds) 0 \(try #require(steps.first).timeStepSeconds)" + (analysis.initialization == "uic" ? " uic" : "")
                for (id, value) in analysis.uicInitialUnknowns ?? [:] {
                    guard id.hasPrefix("net:") else { throw OSDIDCManifest.Failure.invalidManifest }
                    source = source.replacingOccurrences(of: ".op\n", with: ".ic V(\(id.dropFirst(4)))=\(value)\n.op\n")
                }
            default: throw OSDIDCManifest.Failure.invalidManifest
            }
            source = source.replacingOccurrences(of: ".op\n", with: command + "\n")
            try source.write(to: fixture.deck, atomically: true, encoding: .utf8)
            return fixture
        } catch { helper.cleanup(fixture); throw error }
    }
    private func preparedTerminalNames(_ device: OSDIDCManifest.Device, input: Input) async throws -> [String] {
        let metadata = try #require(input.manifest.libraries.first { $0.id == device.library })
        let path = URL(fileURLWithPath: metadata.path)
        let byteCount = try #require(FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber).uint64Value
        let reference = try ArtifactReference(digest: .init(algorithm: .sha256, hexadecimalValue: metadata.sha256),
            byteCount: byteCount, descriptor: .init(role: .input, kind: .model, format: .unknown))
        let rootID = try ArtifactRootID(rawValue: UUID().uuidString)
        let intent = try ArtifactAccessIntent(expectedReference: reference,
            availability: .local(artifactID: reference.id, rootID: rootID,
                relativePath: .init(segments: [path.lastPathComponent])), operation: .read,
            budget: .init(maximumPageByteCount: 65536, maximumTotalByteCount: max(byteCount, 65536),
                maximumPageCount: 16384, maximumWorkUnitCount: 32768, maximumDurationNanoseconds: 10_000_000_000))
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("osdi-cli-topology-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: staging) }
            catch { Issue.record("Model topology staging cleanup failed: \(error)") }
        }
        let provider = try SPICEOSDILocalLibraryProvider(rootID: rootID, directoryURL: path.deletingLastPathComponent(),
            intents: [intent], stagingParentDirectory: staging, digester: SHA256ContentDigester())
        let library = try await provider.load(reference: reference,
            limits: .init(maximumDescriptors: 16, maximumMetadataBytes: 4 * 1024 * 1024, maximumStorageBytes: 4 * 1024 * 1024))
        let names: [String]
        do {
            let descriptor = try #require(library.descriptors.first { Int($0.index) == device.descriptorIndex })
            try #require(descriptor.name == metadata.descriptorName)
            if metadata.id == "soi101" { try #require(descriptor.terminalCount == 6) }
            let options = try OSDIPreparationOptions(parameters: device.parameters.map { try $0.assignment() },
                simulationParameters: [], temperatureKelvin: device.temperatureKelvin,
                connectedTerminalCount: device.connectedTerminalCount,
                limits: .init(maximumWorkspaceBytes: 8 * 1024 * 1024, maximumDiagnosticCount: 256,
                    maximumDiagnosticBytes: 65536, maximumStringBytes: 65536))
            var model = try OSDINativeModelPreparer().prepare(library: library,
                descriptorIndex: device.descriptorIndex, options: options)
            defer { model.close() }
            if metadata.id == "soi101" {
                try #require(model.topology.nodes.prefix(6).map(\.name) == ["d", "g", "s", "e", "b", "t"])
            }
            try #require(model.topology.nodes.count >= device.connectedTerminalCount)
            names = try model.topology.nodes.prefix(device.connectedTerminalCount).map { node in
                _ = try #require(device.terminals[node.name])
                return node.name
            }
        } catch { try library.close(); throw error }
        try library.close()
        return names
    }
    private func rowIDs(_ point: OSDIAnalysisManifest.Case, execution: CoreSpiceCLIOSDIExecutionRecord,
                        models: [CoreSpiceCLIOSDIRecord]) throws -> [String] {
        var names: [String?] = Array(repeating: nil, count: execution.rows.count)
        let circuit = point.input.circuit
        let nets = Set(circuit.devices.flatMap { $0.terminals.values } + (circuit.resistors + circuit.voltageSources + circuit.currentSources).flatMap { [$0.positive, $0.negative] })
        for row in execution.rows {
            if let name = row.sourceName {
                if row.kind == "node", let original = nets.first(where: { $0.lowercased() == name }) { names[row.row] = "net:" + original }
                if row.kind == "branch", let original = circuit.voltageSources.first(where: { $0.id.lowercased() == name }) { names[row.row] = "branch:" + original.id }
            }
        }
        for model in models where model.phase == execution.analysis {
            let device = try #require(circuit.devices.first { ("n_" + $0.id.lowercased()) == model.instanceName })
            for (index, row) in model.rawNodeGlobalRows.enumerated() {
                guard let row else { continue }
                let raw = model.rawNodeNames[index]
                let id: String
                if let net = device.terminals[raw] { id = "net:" + net }
                else { id = "device:" + device.id + ":node:" + raw }
                if let existing = names[row] { if device.terminals[raw] != nil { #expect(existing == id) } } else { names[row] = id }
            }
        }
        let result = try names.map { try #require($0) }
        #expect(Set(result).count == result.count)
        return result
    }
    private func compareCSV(_ execution: CoreSpiceCLIOSDIExecutionRecord, path: String) throws {
        let csv = try CSVWaveformReader().read(contentsOfFile: path)
        #expect(csv.pointCount == execution.coordinates.count)
        let columns = execution.projection?.columns ?? execution.projectedColumns.map { execution.columns[$0] }
        #expect(csv.variableCount == columns.count)
        func compare(_ actual: Double, _ expected: Double) { #expect(abs(actual - expected) <= max(abs(expected) * 8e-15, Double.leastNonzeroMagnitude)) }
        for column in columns.indices {
            #expect(csv.variables[column].name == columns[column].name)
            #expect(csv.variables[column].unit.rawValue == columns[column].unit)
            for point in execution.coordinates.indices {
                compare(try #require(csv.sweepValue(at: point)), execution.coordinates[point])
                let index = execution.projection == nil ? point * execution.columns.count + execution.projectedColumns[column] : point * columns.count + column
                let real = execution.projection?.real ?? execution.real
                let imaginary: [Double]?
                if let projection = execution.projection { imaginary = projection.imaginary } else { imaginary = execution.imaginary }
                if let imaginary {
                    let value = try #require(csv.complexValue(variable: column, point: point))
                    compare(value.real, real[index]); compare(value.imag, imaginary[index])
                } else { compare(try #require(csv.realValue(variable: column, point: point)), real[index]) }
            }
        }
        if execution.analysis == "noise" {
            #expect(csv.metadata.analysisType == .noise)
            let metric = CoreSpiceCLIMetricSemantics.waveform(csv.variables[1])
            #expect(metric.declaredUnit == execution.noise?.inputReferredUnit && metric.unitMeaning == "declared-waveform-header-unit")
        }
    }
    private func validate(_ point: OSDIAnalysisManifest.Case, input: Input, fixture: OSDICLIExecutionTests.Fixture,
                          execution: CoreSpiceCLIOSDIExecutionRecord, models: [CoreSpiceCLIOSDIRecord]) async throws {
        let ids = try rowIDs(point, execution: execution, models: models)
        func unknowns(_ values: [Double], imaginary: [Double]? = nil) -> [[String: Any]] {
            execution.rows.map { row in
                var result: [String: Any] = ["id": ids[row.row], "unit": row.unit]
                if let imaginary { result["real"] = values[row.row]; result["imag"] = imaginary[row.row] }
                else { result["value"] = values[row.row] }
                return result
            }
        }
        var candidate: [String: Any] = ["kind": point.kind, "status": "passed", "schema": "corespice.osdi.analysis-result.v1"]
        if let op = execution.operatingPoint { candidate["operatingPoint"] = unknowns(op) }
        else { candidate["operatingPoint"] = NSNull() }
        var points: [[String: Any]] = []
        for sample in execution.coordinates.indices {
            var result: [String: Any] = [point.kind == "transient" ? "timeSeconds" : "frequencyHz": execution.coordinates[sample]]
            if let noise = execution.noise {
                result["outputDensity"] = noise.outputDensity[sample]
                result["inputReferredDensity"] = noise.inputReferredDensity[sample]
                result["inputReferredUnit"] = noise.inputReferredUnit.replacingOccurrences(of: "²", with: "^2")
                result["channels"] = try noise.channels.map { channel -> [String: Any] in
                    let device = point.input.circuit.devices.first { ("n_" + $0.id.lowercased()) == channel.deviceName }
                    let original: String
                    if let device { original = device.id }
                    else { original = try #require(point.input.circuit.resistors.first { $0.id.lowercased() == channel.deviceName }).id }
                    let id = device == nil ? "resistor:" + original + ":thermal" : "device:" + original + ":noise:" + String(channel.sourceIndex)
                    return ["id": id, "index": channel.sourceIndex, "name": channel.sourceName, "residualUnit": channel.residualUnit,
                            "density": channel.sourceDensity[sample], "outputDensity": channel.outputDensity[sample]]
                }
            } else {
                let start = sample * execution.columns.count, end = start + execution.columns.count
                result["unknowns"] = unknowns(Array(execution.real[start..<end]), imaginary: execution.imaginary.map { Array($0[start..<end]) })
            }
            points.append(result)
        }
        candidate["points"] = points
        if let noise = execution.noise { candidate["integratedOutputNoise"] = noise.integratedOutputNoise }
        if point.kind == "transient" {
            candidate["acceptedSteps"] = execution.acceptedSteps.map { ["timeSeconds": $0.timeSeconds, "timeStepSeconds": $0.timeStepSeconds, "method": $0.method] as [String: Any] }
        }
        let candidatePath = fixture.root.appendingPathComponent("candidate-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys]).write(to: candidatePath)
        var arguments = Array(point.validationBaseCommand.dropFirst())
        arguments += ["--candidate", candidatePath.path, "--output", fixture.root.appendingPathComponent("validated-\(UUID().uuidString)").path]
        let result = try await helper.process(executable: #require(point.validationBaseCommand.first), arguments: arguments)
        try #require(result.status == 0, "\(point.id): \(result.text)")
    }

    @Test func realTransientCasesHaveExactFullPrecisionWitnessOwners() throws {
        let input = try input()
        let delegated = input.manifest.cases.filter { $0.family != nil && $0.kind == "transient" }
        #expect(delegated.count == 12 && delegated.allSatisfy { $0.expectedOutcome == "passed" })
        #expect(Set(delegated.map(\.id)) == Set(Self.realTransientPrecisionOwners.keys))
        #expect(Set(Self.realTransientPrecisionOwners.values).count == 12)
        #expect(input.manifest.cases.filter(usesOrdinaryWitness).count + delegated.count == 50)
        for point in delegated {
            let owner = try #require(Self.realTransientPrecisionOwners[point.id])
            print("Real transient CLI owner \(point.id): OSDIPrecisionFullScheduleCLITests.\(owner)")
        }
    }

    private func replayBatchPrepared(_ point: OSDIAnalysisManifest.Case, input: Input) async throws {
        let fixture = try await fixture(point, input: input); defer { helper.cleanup(fixture) }
        let args = ["-b", fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path, "--json"]
        var session = try Session(policy: .developerV1())
        var stage = "ordinary execution"
        do {
            let output = try await CLI(arguments: args).executeBatch(options: .init(arguments: args), session: &session)
            #expect(point.expectedOutcome == "passed", "\(point.id): expected completed reference")
            stage = "ordinary JSON/CSV reload"
            let bytes = try JSONEncoder().encode(output)
            let saved = fixture.root.appendingPathComponent("batch.json"); try bytes.write(to: saved)
            let reloaded = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: Data(contentsOf: saved))
            let execution = try #require(reloaded.osdiExecution), models = try #require(reloaded.osdiModels)
            if point.kind == "noise", point.family != nil {
                stage = "legacy OSDI noise intent cold reload"
                var legacy = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                legacy["bsim4Models"] = []; legacy["bsim45Models"] = []
                legacy["bsim4NoisePreparationRequested"] = true
                legacy["bsim4PreparationPolicy"] = NSNull()
                let legacySaved = fixture.root.appendingPathComponent("legacy-noise-batch.json")
                try JSONSerialization.data(withJSONObject: legacy).write(to: legacySaved)
                let compatible = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self,
                    from: Data(contentsOf: legacySaved))
                #expect(compatible == reloaded)
                let currentBytes = try JSONEncoder().encode(compatible)
                let current = try #require(JSONSerialization.jsonObject(with: currentBytes) as? [String: Any])
                for key in ["bsim4Models", "bsim45Models", "bsim4NoisePreparationRequested", "bsim4PreparationPolicy"] {
                    #expect(current[key] == nil)
                }
            }
            try compareCSV(execution, path: fixture.csv.path)
            stage = "ordinary independent candidate validation"
            try await validate(point, input: input, fixture: fixture, execution: execution, models: models)
            stage = "prepared execution"
            let preparedCSV = fixture.root.appendingPathComponent("prepared.csv")
            let prepared = try await CoreSpicePreparedCommand(arguments: [fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", preparedCSV.path]).execute()
            stage = "prepared JSON/CSV reload"
            let record = try CoreSpiceCLIPreparedRunRecord(prepared)
            let preparedSaved = fixture.root.appendingPathComponent("prepared.json")
            try JSONEncoder().encode(record).write(to: preparedSaved)
            let repeated = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(contentsOf: preparedSaved))
            let complete = try #require(repeated.osdiExecution)
            #expect(complete == execution && repeated.osdiModels == models)
            try compareCSV(complete, path: preparedCSV.path)
        } catch {
            print("OSDI CLI S4 \(point.id) [\(stage)] failed: \(error)")
            throw error
        }
    }

    @Test func ordinaryACNoiseAndAnalyticTransientBatchPreparedSaveReloadAndIndependentCandidate() async throws {
        let input = try input()
        #expect(input.manifest.cases.count == 50)
        try #require(input.manifest.cases.filter(usesOrdinaryWitness).allSatisfy { $0.expectedOutcome == "passed" })
        var successes = 0
        for point in input.manifest.cases where usesOrdinaryWitness(point) {
            try await replayBatchPrepared(point, input: input)
            successes += 1
        }
        #expect(successes == 38)
    }
    @Test func ordinarySelectedCSVStrictReloadCancellationBudgetAndRetainedRerun() async throws {
        let input = try input()
        for caseID in ["bsim-n-loaded-s4-ac", "analytic-uic-rc", "bsim-n-loaded-s4-noise"] {
            let point = try #require(input.manifest.cases.first { $0.id == caseID })
            let kind = point.kind
            let fixture = try await fixture(point, input: input); defer { helper.cleanup(fixture) }
            let selection = kind == "transient" ? ".save I(VREF) V(p)" : ".save I(VG) V(d)"
            if kind != "noise" {
                let source = try String(contentsOf: fixture.deck, encoding: .utf8)
                try source.replacingOccurrences(of: ".end\n", with: selection + "\n.end\n").write(to: fixture.deck, atomically: true, encoding: .utf8)
            }
            var output: SPICENativeSimulationOutput? = try await CoreSpicePreparedCommand(arguments: [fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path]).execute()
            let saved = try CoreSpiceCLIPreparedRunRecord(#require(output))
            let execution = try #require(saved.osdiExecution)
            let auditSaved = fixture.root.appendingPathComponent("complete-clock-audit.json")
            try JSONEncoder().encode(saved).write(to: auditSaved)
            let auditReloaded = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(contentsOf: auditSaved))
            #expect(auditReloaded.osdiExecution == execution)
            if kind == "transient" {
                #expect(execution.acceptedSteps.count == execution.coordinates.count - 1)
                for (index, step) in execution.acceptedSteps.enumerated() {
                    let delta = execution.coordinates[index + 1] - execution.coordinates[index]
                    #expect(abs(step.timeStepSeconds - delta) <= max(abs(step.timeSeconds), step.timeStepSeconds) * 64 * Double.ulpOfOne)
                }
            }
            try compareCSV(execution, path: fixture.csv.path)
            if kind != "noise" { #expect(execution.projectedColumns.count == 2 && execution.rows.count > 2) }
            let corruptions = ["schema", "values", "rows", "phase", "op", "coordinates", "mapping", "noise-or-step"]
                + (kind == "noise" ? ["noise-sweep", "noise-zero-coordinate", "noise-endpoint", "noise-channel-sum", "noise-integral"] : [])
                + (kind == "transient" ? ["step-width", "step-time"] : [])
            for corruption in corruptions {
                var json = try #require(helper.object(saved) as? [String: Any])
                var evidence = try #require(json["osdiExecution"] as? [String: Any])
                switch corruption {
                case "schema": evidence["schemaVersion"] = 99
                case "values": evidence["real"] = []
                case "rows":
                    var rows = try #require(evidence["rows"] as? [[String: Any]])
                    rows[1]["row"] = 0; evidence["rows"] = rows
                case "phase":
                    var models = try #require(json["osdiModels"] as? [[String: Any]])
                    models.append(models[0]); json["osdiModels"] = models
                case "op": evidence["operatingPoint"] = []
                case "coordinates": evidence["coordinates"] = [1.0, 0.0]
                case "mapping":
                    var models = try #require(json["osdiModels"] as? [[String: Any]])
                    models[0]["rawNodeGlobalRows"] = [99999]; json["osdiModels"] = models
                case "noise-sweep": evidence["sweepUnit"] = "s"
                case "noise-zero-coordinate":
                    var coordinates = try #require(evidence["coordinates"] as? [Double]); coordinates[0] = 0; evidence["coordinates"] = coordinates
                case "noise-endpoint":
                    var noise = try #require(evidence["noise"] as? [String: Any])
                    var channels = try #require(noise["channels"] as? [[String: Any]])
                    let row = try #require(execution.rows.first { $0.unit == "V" }).row
                    channels[0]["positiveRow"] = row; channels[0].removeValue(forKey: "negativeRow"); channels[0]["residualUnit"] = "W"
                    noise["channels"] = channels; evidence["noise"] = noise
                case "noise-channel-sum":
                    var noise = try #require(evidence["noise"] as? [String: Any])
                    var channels = try #require(noise["channels"] as? [[String: Any]])
                    var density = try #require(channels[0]["outputDensity"] as? [Double])
                    let total = try #require(noise["outputDensity"] as? [Double])
                    density[0] += max(total[0], Double.leastNormalMagnitude); channels[0]["outputDensity"] = density
                    noise["channels"] = channels; evidence["noise"] = noise
                case "noise-integral":
                    var noise = try #require(evidence["noise"] as? [String: Any])
                    let rms = try #require(noise["integratedOutputNoise"] as? Double) * 2
                    noise["integratedOutputNoise"] = rms; evidence["noise"] = noise
                    var real = try #require(evidence["real"] as? [Double])
                    for point in execution.coordinates.indices { real[point * 3 + 2] = rms }; evidence["real"] = real
                case "step-width", "step-time":
                    var steps = try #require(evidence["acceptedSteps"] as? [[String: Any]])
                    if corruption == "step-width" {
                        steps[0]["timeStepSeconds"] = try #require(steps[0]["timeStepSeconds"] as? Double) * 2
                    } else {
                        steps[0]["timeSeconds"] = try #require(steps[0]["timeSeconds"] as? Double) + #require(steps[0]["timeStepSeconds"] as? Double) / 2
                    }
                    evidence["acceptedSteps"] = steps
                case "noise-or-step":
                    if kind == "noise" { evidence.removeValue(forKey: "noise") }
                    else if kind == "ac" { evidence.removeValue(forKey: "imaginary") }
                    else { evidence["acceptedSteps"] = [] }
                default: throw OSDIDCManifest.Failure.invalidManifest
                }
                json["osdiExecution"] = evidence
                let bytes = try JSONSerialization.data(withJSONObject: json)
                do { _ = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: bytes); Issue.record("Corrupt dynamic evidence decoded: \(corruption)") }
                catch { #expect(error is CoreSpiceCLIOSDIError || error is DecodingError) }
            }
            let retainedInput = try #require(output?.prepared.input)
            let retainedLimits = try #require(output?.prepared.limits)
            let runtime = try #require(output?.prepared.osdiRuntimeInputs)
            let identity = try #require(output?.configurationIdentity)
            output = nil
            let native = SPICENativeSimulation()
            let prepared = try await native.prepare(retainedInput, limits: retainedLimits, osdi: runtime)
            let rerun = try await native.execute(prepared, cancellation: .init())
            let repeated = try CoreSpiceCLIPreparedRunRecord(rerun)
            #expect(rerun.configurationIdentity == identity && repeated.osdiExecution == saved.osdiExecution && repeated.osdiModels == saved.osdiModels)
            try FileManager.default.removeItem(at: fixture.csv)
            let cancellation = CancellationToken(); cancellation.cancel()
            do { _ = try await CoreSpicePreparedCommand(arguments: [fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path]).execute(cancellation: cancellation); Issue.record("Cancelled prepared command completed") }
            catch { #expect(!FileManager.default.fileExists(atPath: fixture.csv.path)) }
            let loaded = try CoreSpiceCLIOSDICatalog.load(path: fixture.catalog.path)
            var session = try Session(policy: .developerV1())
            // A separately loaded typed catalog uses the same source capture entrypoint as batch.
            let deck = try await SPICEDeckLoader.loadFile(at: fixture.deck.path)
            try session.loadNetlist(deck, osdiCatalog: loaded)
            let sessionWaveform = try await session.runParsed(session.requiredDefaultRunnableAnalysis())
            #expect(sessionWaveform.pointCount == execution.coordinates.count && session.completedOSDIExecution == execution)
            do { _ = try await session.runParsed(session.requiredDefaultRunnableAnalysis(), cancellation: cancellation); Issue.record("Cancelled ordinary command completed") }
            catch { #expect(session.completedOSDIModels.isEmpty) }
            if kind == "ac" {
                let source = try String(contentsOf: fixture.deck, encoding: .utf8)
                try source.replacingOccurrences(of: ".save I(VG) V(d)", with: ".print ac db(V(d)) phase(V(d))").write(to: fixture.deck, atomically: true, encoding: .utf8)
                let transformed = try await CoreSpicePreparedCommand(arguments: [fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path]).execute()
                let record = try CoreSpiceCLIPreparedRunRecord(transformed)
                let evidence = try #require(record.osdiExecution)
                #expect(evidence.projection?.columns.count == 2 && evidence.real == execution.real && evidence.imaginary == execution.imaginary)
                try compareCSV(evidence, path: fixture.csv.path)
                try FileManager.default.removeItem(at: fixture.csv)
            }
            var catalog = fixture.json; catalog["maximumAdapterBytes"] = 1
            try JSONSerialization.data(withJSONObject: catalog).write(to: fixture.catalog)
            do { _ = try await CoreSpicePreparedCommand(arguments: [fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path]).execute(); Issue.record("Insufficient adapter budget completed") }
            catch { #expect(!FileManager.default.fileExists(atPath: fixture.csv.path)) }
        }
    }

    private func replayExecutable(_ point: OSDIAnalysisManifest.Case, input: Input, executable: String) async throws {
        let fixture = try await fixture(point, input: input); defer { helper.cleanup(fixture) }
        let args = ["-b", fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path, "--json"]
        let result = try await helper.process(executable: executable, arguments: args)
        try #require(result.status == 0, "\(result.text)")
        let batchSaved = fixture.root.appendingPathComponent("executable-batch.json")
        try Data(result.text.utf8).write(to: batchSaved)
        let record = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: Data(contentsOf: batchSaved))
        let execution = try #require(record.osdiExecution)
        try compareCSV(execution, path: fixture.csv.path)
        try await validate(point, input: input, fixture: fixture, execution: execution, models: #require(record.osdiModels))
        let preparedCSV = fixture.root.appendingPathComponent("executable-prepared.csv")
        let prepared = try await helper.process(executable: executable, arguments: ["prepared", fixture.deck.path, "--osdi-catalog", fixture.catalog.path, "--csv", preparedCSV.path, "--json"])
        try #require(prepared.status == 0, "\(prepared.text)")
        let preparedSaved = fixture.root.appendingPathComponent("executable-prepared.json")
        try Data(prepared.text.utf8).write(to: preparedSaved)
        let receipt = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(contentsOf: preparedSaved))
        #expect(receipt.osdiExecution == execution && receipt.osdiModels == record.osdiModels)
        try compareCSV(try #require(receipt.osdiExecution), path: preparedCSV.path)
    }

    @Test func realExecutableACNoiseAndAnalyticTransientsPublishCompleteJSONAndCSV() async throws {
        let input = try input()
        let executable = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_CLI_EXECUTABLE"])
        var visited = Set<String>()
        for point in input.manifest.cases where point.expectedOutcome == "passed"
            && ((point.family != nil && point.kind != "transient") || (point.family == nil && point.kind == "transient")) {
            let key = point.family.map { $0 + ":" + point.kind } ?? point.id
            guard visited.insert(key).inserted else { continue }
            try await replayExecutable(point, input: input, executable: executable)
        }
        #expect(visited.count == 12)
    }

    @Test func ordinaryIMGThermalTransientRefusesWithoutCompletedArtifacts() async throws {
        let input = try input()
        let point = try #require(input.manifest.cases.first { $0.id == "img-n-thermal-s4-transient" })
        let fixture = try await fixture(point, input: input); defer { helper.cleanup(fixture) }
        let executable = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_CLI_EXECUTABLE"])
        for command in ["-b", "prepared"] {
            let csv = fixture.root.appendingPathComponent(command == "-b" ? "thermal-batch.csv" : "thermal-prepared.csv")
            let result = try await helper.process(executable: executable, arguments: [command, fixture.deck.path,
                "--osdi-catalog", fixture.catalog.path, "--csv", csv.path, "--json"])
            try #require(result.status == 2, "Ordinary IMG thermal completed unexpectedly: \(result.text.prefix(1024))")
            let bytes = Data(result.text.utf8)
            let failure = try JSONDecoder().decode(CoreSpiceCLIFailure.self, from: bytes)
            #expect(failure.status == "failed" && failure.code == "analysis.timestep-too-small")
            let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(json["osdiExecution"] == nil && json["osdiModels"] == nil)
            #expect(!FileManager.default.fileExists(atPath: csv.path))
        }
    }

}

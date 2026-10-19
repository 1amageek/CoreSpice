import CoreSpice
import CoreSpiceEvent
import CoreSpiceExporterCSV
import CoreSpiceIO
import CircuiteFoundation
import ToolQualification
import CoreSpiceOSDITestSupport
import CoreSpiceWaveform
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite(.timeLimit(.minutes(3)))
struct OSDICompositeAnalysisCLITests {
    private struct CompositeStageFailure: Error, CustomStringConvertible {
        let modelCase: String
        let analysis: String
        let underlying: any Error
        var description: String { "Composite CLI case \(modelCase), directive \(analysis): \(underlying)" }
    }
    @Test(arguments: ["bsim-p-selfheat-loaded", "cmg-n-selfheat-series-loaded", "img-n-loaded", "soi101-n-dd-hot-series-thermal"])
    func ordinarySourceSensitivityPublishesExactFourFamilyCases(_ id: String) async throws {
        let helper = OSDICLIExecutionTests()
        let manifest = try helper.manifest()
        let point = try #require(manifest.cases.first { $0.id == id })
        let gate = try #require(point.input.voltageSources.first { ["VG", "VFG"].contains($0.id) })
        for ac in [false, true] {
            let fixture = try helper.fixture(point, manifest: manifest)
            defer { helper.cleanup(fixture) }
            let original = try String(contentsOf: fixture.deck, encoding: .utf8)
            let analysis = ac ? ".sens V(d) ac lin 2 100 200" : ".sens V(d)"
            let lines = original.replacingOccurrences(of: ".op\n", with: analysis + "\n")
                .components(separatedBy: "\n").map { line in
                    line.split(whereSeparator: \.isWhitespace).first?.lowercased() == gate.id.lowercased() ? line + " AC 1" : line
                }
            try lines.joined(separator: "\n").write(to: fixture.deck, atomically: true, encoding: .utf8)
            let directory = fixture.root.appendingPathComponent("case")
            var args = ["-b", fixture.deck.path, "--osdi-catalog", fixture.catalog.path,
                "--case-output", directory.path, "--case-id", id + (ac ? "-ac" : "-dc"),
                "--csv", fixture.csv.path, "--json"]
            var selectedProfile: (profile: CoreSpiceCLIExecutionProfile, reference: ArtifactReference)?
            if id == "soi101-n-dd-hot-series-thermal" {
                let profileURL = fixture.root.appendingPathComponent("execution-profile.json")
                let fields: [String: Any] = ["schemaVersion": 1, "maximumElements": 8192,
                    "maximumNativeAllocationBytes": 67108864, "maximumLiveOwnedBytes": 150994944,
                    "maximumTemporaryBytes": 67108864, "maximumHashedBytes": 67108864,
                    "maximumSourceBytes": 1048576, "maximumPreparationWorkUnits": 1000000000,
                    "maximumResolutionRetainedBytes": 16777216]
                try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).write(to: profileURL)
                selectedProfile = try CoreSpiceCLIExecutionProfile.load(path: profileURL.path)
                args += ["--execution-profile", profileURL.path]
            }
            var session = try Session(policy: .developerV1())
            let batch = try await CLI(arguments: args).executeBatch(options: .init(arguments: args), session: &session)
            #expect(batch.schemaVersion.major == 7)
            let bytes = try JSONEncoder().encode(batch)
            var legacyEmpty = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            for key in ["bsim4Models", "bsim45Models", "bsim4NoisePreparationRequested", "bsim4PreparationPolicy"] {
                #expect(legacyEmpty[key] == nil)
            }
            legacyEmpty["bsim4Models"] = []; legacyEmpty["bsim45Models"] = []
            legacyEmpty["bsim4NoisePreparationRequested"] = false; legacyEmpty["bsim4PreparationPolicy"] = NSNull()
            let compatible = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self,
                from: JSONSerialization.data(withJSONObject: legacyEmpty))
            #expect(compatible == batch)
            legacyEmpty["bsim4Models"] = [["device": "m1"]]
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self,
                    from: JSONSerialization.data(withJSONObject: legacyEmpty))
            }
            let batchURL = fixture.root.appendingPathComponent("batch.json")
            try bytes.write(to: batchURL)
            let reloaded = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: Data(contentsOf: batchURL))
            #expect(reloaded == batch)
            #expect(reloaded.executionProfile == selectedProfile?.profile)
            #expect(reloaded.executionProfileReference == selectedProfile?.reference)
            if let selectedProfile { #expect(reloaded.inputArtifacts.contains(selectedProfile.reference)) }
            let completion = try #require(batch.analysisCompletions?.first)
            let json = try #require(completion.preparedCompletionJSON)
            let sourceBytes = Data(json.utf8)
            let sourceReference = try #require(completion.preparedCompletionArtifact)
            #expect(try CoreSpiceCLISourceCompletion.reference(sourceBytes) == sourceReference)
            #expect(try Data(contentsOf: directory.appendingPathComponent("source-completion-0.json")) == sourceBytes)
            let saved = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: sourceBytes)
            #expect(saved.schemaVersion == 7 && saved.analysis == "sens")
            let waveform = try #require(saved.savedWaveform)
            let csv = try CSVWaveformReader().read(contentsOfFile: fixture.csv.path)
            #expect(csv.variables.map(\.name) == waveform.variables.map(\.name))
            #expect(csv.sweepValues.map(\.bitPattern) == waveform.coordinates.map(\.bitPattern))
            #expect(csv.pointCount == waveform.coordinates.count)
            for pointIndex in waveform.coordinates.indices {
                for variableIndex in waveform.variables.indices {
                    let index = pointIndex * waveform.variables.count + variableIndex
                    // Ordinary CSV retains the existing 15-digit display format; JSON retains exact values.
                    if let imaginary = waveform.imaginary {
                        let actual = try #require(csv.complexValue(variable: variableIndex, point: pointIndex))
                        #expect(abs(actual.real - waveform.real[index]) <= max(Double.leastNonzeroMagnitude, abs(waveform.real[index]) * 1e-14))
                        #expect(abs(actual.imag - imaginary[index]) <= max(Double.leastNonzeroMagnitude, abs(imaginary[index]) * 1e-14))
                    } else {
                        let actual = try #require(csv.realValue(variable: variableIndex, point: pointIndex))
                        #expect(abs(actual - waveform.real[index]) <= max(Double.leastNonzeroMagnitude, abs(waveform.real[index]) * 1e-14))
                    }
                }
            }
            let evidenceBytes = try Data(contentsOf: directory.appendingPathComponent("sensitivity-0.json"))
            let evidence = try JSONDecoder().decode(CoreSpiceCLISensitivityEvidence.self, from: evidenceBytes)
            #expect(evidence.analysis == (ac ? "sens-ac" : "sens-dc"))
            #expect(evidence.frequencies == (ac ? [100, 200] : []))
            #expect(evidence.children.map(\.source) == saved.sourceReexecutions)
            var suppliedRealParameters = 0
            for device in point.input.devices {
                for parameter in device.parameters {
                    if case .real = try parameter.assignment().value { suppliedRealParameters += 1 }
                }
            }
            let expectedChildren = point.input.resistors.count + point.input.voltageSources.count
                + point.input.currentSources.count + 1 + suppliedRealParameters
            #expect(evidence.children.count == expectedChildren)
            #expect(Set(evidence.children.map { $0.instance + "." + $0.parameter }).count == expectedChildren)
            #expect(evidence.sourceInputIdentity == saved.sourceInputIdentity)
            #expect(batch.outputArtifacts.contains(sourceReference))
            #expect(evidence.sourceArtifacts.allSatisfy { batch.inputArtifacts.contains($0) })
            #expect((try #require(saved.osdiModels)).allSatisfy { batch.inputArtifacts.contains($0.artifact) })
            if !ac {
                let reference = try #require(point.reference.unknowns?.first { $0.id == "net:d" })
                #expect(abs(evidence.baseline[0].real - reference.value) <= max(1e-8, abs(reference.value) * 1e-6))
            } else { #expect(evidence.baseline.contains { abs($0.real) > 1e-12 }) }
            let execution = try ToolQualificationCaseExecution.decodeCanonical(from: Data(contentsOf: directory.appendingPathComponent("execution.json")))
            let semantics = try JSONDecoder().decode([String: CoreSpiceCLIMetricSemantics].self,
                from: Data(contentsOf: directory.appendingPathComponent("metric-domain.json")))
            let derivation = try CoreSpiceCLIArtifactReferencer().output(path: directory.appendingPathComponent("sensitivity-0.json").path,
                kind: .report, format: .json)
            #expect(Set(semantics.keys) == Set(execution.observedMetrics.keys))
            #expect(semantics.values.allSatisfy { $0.derivationArtifact == derivation && $0.sourceCompletionArtifact == sourceReference })
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let receipts = try files.filter { $0.lastPathComponent.hasPrefix("model-receipt-") }.map {
                try ToolQualificationModelExecutionReceipt.decodeCanonical(from: Data(contentsOf: $0))
            }
            for device in point.input.devices {
                let name = "n_" + device.id.lowercased()
                for parameter in device.parameters {
                    let assignment = try parameter.assignment()
                    guard case .real(let nominal) = assignment.value else { continue }
                    let role = assignment.scope == .model ? "model" : "instance"
                    let child = try #require(evidence.children.first { $0.instance == name && $0.parameter == role + "." + assignment.name })
                    #expect(child.nominalBits == nominal.bitPattern)
                    #expect(child.replacementBits != child.nominalBits)
                    #expect(child.source.physicalAnalysis == (ac ? "ac" : "op"))
                    #expect(child.source.sourceOverrides.isEmpty)
                    let descriptor = try #require(child.source.osdiPatchDescriptorIndex)
                    let model = try #require(child.source.osdiModels.first { $0.instanceName == name })
                    let consumed = model.resolvedParameters.filter { $0.scope == role && $0.descriptorIndex == descriptor }
                    try #require(consumed.count == 1)
                    let fact = try #require(consumed.first)
                    #expect(fact.isGiven == true)
                    #expect(try fact.assignment().value == .real(Double(bitPattern: child.replacementBits)))
                    #expect(batch.inputArtifacts.contains(model.artifact))
                    let actual = role == "model" ? model.modelParameters : model.instanceParameters
                    #expect(try actual.contains {
                        let resolved = try $0.assignment()
                        return resolved.name == assignment.name && resolved.value == .real(Double(bitPattern: child.replacementBits))
                    })
                    #expect(receipts.contains { receipt in
                        receipt.sourceArtifact == model.artifact && (role == "model"
                            ? receipt.resolvedParameters[assignment.name]?.bitPattern == child.replacementBits
                            : receipt.consumedInstances[name]?[assignment.name]?.bitPattern == child.replacementBits)
                    })
                    let increment = child.increment.real + Double(bitPattern: child.increment.lowBits ?? 0)
                    for index in child.observations.indices {
                        let expected = (child.observations[index].real - evidence.baseline[index].real) / increment
                        #expect(abs(child.absolute[index].real - expected) <= max(1e-8, abs(expected) * 1e-7))
                    }
                }
            }
            for (metric, contributors) in execution.metricPhaseIDs where metric.contains(":derived:") {
                #expect(contributors.count == 2)
                #expect(contributors[0].contains("baseline") && contributors[1].contains("child"))
            }
            // Recompute the outer digest for source tampering so semantic validation must reject it too.
            for corruption in ["missing", "changed-content", "changed-hash", "changed-source", "missing-descriptor", "changed-typed-assignment"] {
                var outer = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                var completions = try #require(outer["analysisCompletions"] as? [[String: Any]])
                if corruption == "missing" { completions[0].removeValue(forKey: "preparedCompletionJSON") }
                else if corruption == "changed-content" { completions[0]["preparedCompletionJSON"] = json + " " }
                else if corruption == "changed-hash" {
                    completions[0]["preparedCompletionArtifact"] = try helper.object(CoreSpiceCLISourceCompletion.reference(Data("changed".utf8)))
                } else {
                    var nested = try #require(JSONSerialization.jsonObject(with: sourceBytes) as? [String: Any])
                    var children = try #require(nested["sourceReexecutions"] as? [[String: Any]])
                    if corruption == "changed-source" {
                        children[0]["sourceInputIdentity"] = String(repeating: "0", count: 64)
                    } else {
                        let index = try #require(evidence.children.firstIndex { $0.source.osdiPatchDescriptorIndex != nil })
                        if corruption == "missing-descriptor" {
                            children[index].removeValue(forKey: "osdiPatchDescriptorIndex")
                        } else {
                            let target = evidence.children[index]
                            let parts = target.parameter.split(separator: ".", maxSplits: 1).map(String.init)
                            try #require(parts.count == 2)
                            var models = try #require(children[index]["osdiModels"] as? [[String: Any]])
                            let modelIndex = try #require(models.firstIndex { ($0["instanceName"] as? String) == target.instance })
                            let key = parts[0] == "model" ? "modelParameters" : "instanceParameters"
                            var parameters = try #require(models[modelIndex][key] as? [[String: Any]])
                            let parameterIndex = try #require(parameters.firstIndex {
                                ($0["name"] as? String)?.caseInsensitiveCompare(parts[1]) == .orderedSame
                            })
                            parameters[parameterIndex]["value"] = Double(bitPattern: target.replacementBits) * 1.5
                            models[modelIndex][key] = parameters; children[index]["osdiModels"] = models
                        }
                        // Keep the two encoded child projections identical so their local typed contract is tested.
                        var derivation = try #require(nested["sensitivityEvidence"] as? [String: Any])
                        var observations = try #require(derivation["children"] as? [[String: Any]])
                        observations[index]["source"] = children[index]
                        derivation["children"] = observations; nested["sensitivityEvidence"] = derivation
                    }
                    nested["sourceReexecutions"] = children
                    let changed = try JSONSerialization.data(withJSONObject: nested, options: [.sortedKeys])
                    completions[0]["preparedCompletionJSON"] = String(decoding: changed, as: UTF8.self)
                    completions[0]["preparedCompletionArtifact"] = try helper.object(CoreSpiceCLISourceCompletion.reference(changed))
                    #expect(throws: (any Error).self) { try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: changed) }
                }
                outer["analysisCompletions"] = completions
                let invalid = try JSONSerialization.data(withJSONObject: outer)
                #expect(throws: (any Error).self) { try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: invalid) }
            }
        }
    }

    @Test func soiSensitivityDefaultLiveCeilingRefusesBeforePublication() async throws {
        let helper = OSDICLIExecutionTests()
        let manifest = try helper.manifest()
        let point = try #require(manifest.cases.first { $0.id == "soi101-n-dd-hot-series-thermal" })
        let gate = try #require(point.input.voltageSources.first { ["VG", "VFG"].contains($0.id) })
        let fixture = try helper.fixture(point, manifest: manifest)
        defer { helper.cleanup(fixture) }
        let original = try String(contentsOf: fixture.deck, encoding: .utf8)
        let lines = original.replacingOccurrences(of: ".op\n", with: ".sens V(d)\n")
            .components(separatedBy: "\n").map { line in
                line.split(whereSeparator: \.isWhitespace).first?.lowercased() == gate.id.lowercased() ? line + " AC 1" : line
            }
        try lines.joined(separator: "\n").write(to: fixture.deck, atomically: true, encoding: .utf8)
        let directory = fixture.root.appendingPathComponent("case")
        let args = ["-b", fixture.deck.path, "--osdi-catalog", fixture.catalog.path,
            "--case-output", directory.path, "--case-id", point.id + "-dc",
            "--csv", fixture.csv.path, "--json"]
        var session = try Session(policy: .developerV1())
        do {
            _ = try await CLI(arguments: args).executeBatch(options: .init(arguments: args), session: &session)
            Issue.record("The complete SOI sensitivity workload exceeded default live admission but published success")
        } catch SPICENativeExecutionError.numerical(let cause) {
            guard case SPICENativePreparationError.resource(let resource) = cause,
                  case SPICESimulationResources.ResourceError.storageLimit = resource else { throw cause }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.csv.path))
    }

    @Test func precisionFourierSavesActualPairedTransientBesideItsSpectrum() async throws {
        let fixture = try await precisionFourierFixture()
        defer { do { try FileManager.default.removeItem(at: fixture.root) } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let completed = try await CoreSpicePreparedCommand(arguments: [fixture.deck.path,
            "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path,
            "--paired-csv", fixture.pairedCSV.path]).executeWithRecord()
        let family = completed.record
        #expect(family.schemaVersion == 6 && family.cases?.count == 1)
        let record = try #require(family.cases?.first).completion
        #expect(record.schemaVersion == 8 && record.analysis == "four")
        let execution = try #require(record.fourierTransientExecution)
        let precision = try #require(execution.precision)
        let transient = try #require(completed.output.fourierResult).transientResult
        #expect(precision.schemaVersion == 2 && precision.settings.analysis == "four")
        #expect(execution.analysis == "tran")
        #expect(precision.highBits == transient.solutionTrace.rowMajorValues.map(\.bitPattern))
        #expect(precision.lowBits == (try #require(transient.solutionLowTrace)).rowMajorValues.map(\.bitPattern))
        #expect(precision.solutionLow.contains { $0 != 0 })
        #expect(precision.coordinateBits == transient.timePoints.map(\.bitPattern))
        #expect(execution.acceptedSteps.count == transient.timePoints.count - 1)
        #expect(record.savedWaveform?.analysis == .fourier)
        #expect(record.savedWaveform?.coordinates != execution.coordinates)
        #expect(try #require(precision.sources.captures.first).bytes == Data(contentsOf: fixture.deck))
        let serialized = try #require(completed.serializedPrecisionJSON)
        let restored = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(serialized.utf8))
        #expect(restored.cases?.first?.completion.fourierTransientExecution == execution)

        let bytes = try Data(contentsOf: fixture.pairedCSV)
        let limits = try CoreSpiceCLIPairedCSVCodec.Limits(maximumBytes: precision.executionBudget.maximumEvidenceBytes,
            maximumPoints: 1000, maximumColumns: execution.rows.count, maximumScalars: 100_000)
        let paired = try CoreSpiceCLIPairedCSVCodec.decode(bytes, limits: limits)
        let expected = try execution.pairedCSVRecord()
        #expect(paired.compiledRows == expected.compiledRows)
        #expect(paired.times.map(\.bitPattern) == expected.times.map(\.bitPattern))
        #expect(paired.high.map(\.bitPattern) == expected.high.map(\.bitPattern))
        #expect(paired.low.map(\.bitPattern) == expected.low.map(\.bitPattern))
        let csv = try familyCSV(fixture.csv)
        let transientRows = csv.filter { $0["phase"] == "transient-high-low" }
        try #require(transientRows.count == execution.real.count)
        #expect(csv.filter { $0["phase"] == "result" }.count == completed.output.waveform.pointCount * completed.output.waveform.variableCount)
        for (index, row) in transientRows.enumerated() {
            #expect(Double(try #require(row["real"]))?.bitPattern == execution.real[index].bitPattern)
            #expect(Double(try #require(row["low"]))?.bitPattern == precision.solutionLow[index].bitPattern)
        }
        for corruption in ["missing-trace", "transient-label", "low-bits"] {
            var envelope = try #require(JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [String: Any])
            var cases = try #require(envelope["cases"] as? [[String: Any]])
            var completion = try #require(cases[0]["completion"] as? [String: Any])
            if corruption == "missing-trace" { completion.removeValue(forKey: "fourierTransientExecution") }
            else {
                var trace = try #require(completion["fourierTransientExecution"] as? [String: Any])
                var details = try #require(trace["precision"] as? [String: Any])
                if corruption == "transient-label" {
                    var settings = try #require(details["settings"] as? [String: Any])
                    settings["analysis"] = "tran"; details["settings"] = settings
                } else {
                    var low = try #require(details["lowBits"] as? [NSNumber])
                    low[0] = NSNumber(value: low[0].uint64Value ^ 1); details["lowBits"] = low
                }
                trace["precision"] = details; completion["fourierTransientExecution"] = trace
            }
            cases[0]["completion"] = completion; envelope["cases"] = cases
            let invalid = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: invalid) }
        }
    }

    @Test func multiplePrecisionFourierCasesRejectPairedPublicationBeforeExecution() async throws {
        let fixture = try await precisionFourierFixture()
        defer { do { try FileManager.default.removeItem(at: fixture.root) } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let original = try String(contentsOf: fixture.deck, encoding: .utf8)
        try original.replacingOccurrences(of: ".end\n", with: ".temp 26 27\n.end\n")
            .write(to: fixture.deck, atomically: true, encoding: .utf8)
        #expect(!FileManager.default.fileExists(atPath: fixture.csv.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.pairedCSV.path))
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        do {
            _ = try await CoreSpicePreparedCommand(arguments: [fixture.deck.path, "--osdi-catalog", fixture.catalog.path,
                "--csv", fixture.csv.path, "--paired-csv", fixture.pairedCSV.path]).executeWithRecord()
            Issue.record("Multiple cases published a single paired trace")
        } catch CoreSpiceCLIOSDIError.unsupportedAnalysis(let message) {
            #expect(message == "paired CSV requires exactly one prepared case")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.csv.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.pairedCSV.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == before)
    }

    @Test(arguments: ["bsim-p-selfheat-loaded", "cmg-n-selfheat-series-loaded", "img-n-loaded", "soi101-n-dd-hot-series-thermal"])
    func exactCapturedFamiliesSaveAndReloadCompositeAnalyses(_ id: String) async throws {
        let helper = OSDICLIExecutionTests()
        let manifest = try helper.manifest()
        let point = try #require(manifest.cases.first { $0.id == id })
        let gate = try #require(point.input.voltageSources.first { ["VG", "VFG"].contains($0.id) })
        let commands = [
            ".dc \(gate.id) \(gate.value) \(gate.value + 1e-5) 1e-5",
            ".tf V(d) \(gate.id)",
            ".pz \(gate.positive) \(gate.negative) d 0 vol pz",
            ".four 1e8 V(d)\n.tran 1e-9 1e-8 0 1e-9"
        ]
        for (index, command) in commands.enumerated() {
            let fixture = try helper.fixture(point, manifest: manifest)
            defer { helper.cleanup(fixture) }
            let original = try String(contentsOf: fixture.deck, encoding: .utf8)
            let source = original.replacingOccurrences(of: ".op\n", with: command + "\n")
            try source.write(to: fixture.deck, atomically: true, encoding: .utf8)
            let completed = try await {
                do {
                    return try await CoreSpicePreparedCommand(arguments: [fixture.deck.path,
                        "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path]).executeWithRecord()
                } catch { throw CompositeStageFailure(modelCase: id, analysis: command, underlying: error) }
            }()
            let output = completed.output
            switch index {
            case 0: #expect(try #require(output.dcSweepResult).results.count == 2)
            case 1: #expect(try #require(output.tfResult).gain.isFinite)
            case 2: #expect(try #require(output.poleZeroResult).dcGain.isFinite)
            default: #expect(try #require(output.fourierResult).transientResult.timePoints.last == 1e-8)
            }
            #expect(completed.record.schemaVersion == 6)
            let record = try #require(completed.record.cases?.first).completion
            let bytes = Data(try CoreSpiceCLIJSON.encode(completed.record).utf8)
            let saved = fixture.root.appendingPathComponent("composite.json")
            try bytes.write(to: saved)
            let family = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(contentsOf: saved))
            #expect(family.cases?.count == 1)
            let reloaded = try #require(family.cases?.first).completion
            #expect(reloaded.status == "succeeded")
            #expect(reloaded.configurationIdentity == output.configurationIdentity.hexadecimalValue)
            #expect(reloaded.points == output.waveform.pointCount)
            #expect(reloaded.osdiModels == record.osdiModels)
            #expect(!(try #require(reloaded.osdiModels)).isEmpty)
            let retained = try #require(reloaded.savedWaveform)
            #expect(retained.real == record.savedWaveform?.real)
            #expect(retained.coordinates == output.waveform.sweepValues)
            if index == 1 {
                let typed = try #require(reloaded.transferFunction)
                let actual = try #require(output.tfResult)
                #expect(typed.schemaVersion == 1 && typed.gainBits == actual.gain.bitPattern)
                #expect(typed.sourceArtifacts == output.prepared.input.sources.map { $0.binding.reference })
                for (saved, native) in [(typed.input, actual.inputPortImpedance), (typed.output, actual.outputPortImpedance)] {
                    switch native {
                    case .finite(let value): #expect(saved.classification == "finite" && saved.valueBits == value.bitPattern)
                    case .openCircuit: #expect(saved.classification == "open_circuit" && saved.valueBits == nil)
                    }
                }
                #expect(retained.options?["input_port_impedance"] == typed.input.classification)
                #expect(retained.options?["output_port_impedance"] == typed.output.classification)
                var invalid = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                var cases = try #require(invalid["cases"] as? [[String: Any]])
                var completion = try #require(cases[0]["completion"] as? [String: Any])
                completion.removeValue(forKey: "transferFunction"); cases[0]["completion"] = completion; invalid["cases"] = cases
                let changed = try JSONSerialization.data(withJSONObject: invalid)
                #expect(throws: (any Error).self) { try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: changed) }
            }
            if index == 0 {
                #expect(reloaded.analysis == "dc")
                let stored = try #require(reloaded.nativeDCResult)
                let sweep = try #require(output.dcSweepResult)
                #expect(stored.analysis == "dc")
                #expect(stored.coordinateBits == sweep.values.map(\.bitPattern))
                #expect(stored.points.map(\.highBits) == sweep.results.map { $0.variables.map(\.bitPattern) })
                let models = try #require(reloaded.osdiModels)
                #expect(models.count == sweep.results.count * point.input.devices.count)
                for pointIndex in sweep.values.indices {
                    let selected = models.filter { $0.sourcePointIndex == pointIndex }
                    #expect(selected.count == point.input.devices.count)
                    #expect(selected.allSatisfy { $0.sourceValueBits == sweep.values[pointIndex].bitPattern
                        && $0.sourceName?.lowercased() == gate.id.lowercased() })
                }
            }
            let csv = try familyCSV(fixture.csv)
            let rows = csv.filter { $0["phase"] == "result" }
            try #require(rows.count == output.waveform.pointCount * output.waveform.variableCount)
            for (offset, row) in rows.enumerated() {
                let sample = offset / output.waveform.variableCount, variable = offset % output.waveform.variableCount
                #expect(row["variable"] == output.waveform.variables[variable].name)
                #expect(Double(try #require(row["coordinate"]))?.bitPattern == output.waveform.sweepValues[sample].bitPattern)
                let realText = try #require(row["real"])
                let actual = try #require(Double(realText))
                if output.waveform.isComplex {
                    let expected = try #require(output.waveform.complexValue(variable: variable, point: sample))
                    let imaginaryText = try #require(row["imaginary"])
                    let imaginary = try #require(Double(imaginaryText))
                    #expect(actual.bitPattern == expected.real.bitPattern)
                    #expect(imaginary.bitPattern == expected.imag.bitPattern)
                } else {
                    let expected = try #require(output.waveform.realValue(variable: variable, point: sample))
                    #expect(actual.bitPattern == expected.bitPattern)
                }
            }
        }
    }

    private func precisionFourierFixture() async throws -> OSDIPrecisionCLIFixture {
        let path = try #require(ProcessInfo.processInfo.environment["CORESPICE_OSDI_PRECISION_MANIFEST"])
        let manifest = try JSONDecoder().decode(OSDIPrecisionManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("osdi-fourier-cli-\(UUID().uuidString)")
        let fixture = try await OSDIPrecisionCLIFixture.make(modelID: "compound", manifest: manifest, root: root)
        do {
            let original = try String(contentsOf: fixture.deck, encoding: .utf8)
            let frequency = 1 / (4 * 0x1p-54)
            try original.replacingOccurrences(of: ".tran ", with: ".four \(frequency) V(p)\n.tran ")
                .write(to: fixture.deck, atomically: true, encoding: .utf8)
            return fixture
        } catch {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Fixture cleanup failed: \(error)") }
            throw error
        }
    }

    private func familyCSV(_ path: URL) throws -> [[String: String]] {
        let text = try String(contentsOf: path, encoding: .utf8)
        var records: [[String]] = [], fields: [String] = [], field = "", quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index], next = text.index(after: index)
            if character == "\"" {
                if quoted, next < text.endIndex, text[next] == "\"" { field.append("\""); index = text.index(after: next); continue }
                quoted.toggle()
            } else if character == "," && !quoted { fields.append(field); field = "" }
            else if character == "\n" && !quoted {
                fields.append(field); records.append(fields); fields = []; field = ""
            } else { field.append(character) }
            index = next
        }
        try #require(!quoted && fields.isEmpty && field.isEmpty)
        let header = try #require(records.first)
        try #require(Set(header).count == header.count)
        return try records.dropFirst().map { fields in
            try #require(fields.count == header.count)
            return Dictionary(uniqueKeysWithValues: zip(header, fields))
        }
    }
}

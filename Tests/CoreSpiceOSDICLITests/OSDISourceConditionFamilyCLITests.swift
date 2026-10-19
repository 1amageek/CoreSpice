import CircuiteFoundation
import CoreSpice
import CoreSpiceOSDITestSupport
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite("OSDI CLI source temperature and seed family", .timeLimit(.minutes(3)))
struct OSDISourceConditionFamilyCLITests {
    @Test(arguments: ["bsim-p-selfheat-loaded", "cmg-n-selfheat-series-loaded", "img-n-loaded", "soi101-n-dd-hot-series-thermal"])
    func everyCasePersistsExactConditionsModelsAndReplay(_ id: String) async throws {
        let helper = OSDICLIExecutionTests()
        let manifest = try helper.manifest()
        let point = try #require(manifest.cases.first { $0.id == id })
        let fixture = try helper.fixture(point, manifest: manifest)
        defer { helper.cleanup(fixture) }
        let gate = try #require(point.input.voltageSources.first { ["VG", "VFG"].contains($0.id) })
        let temperature = try #require(point.input.devices.first).temperatureKelvin - 273.15
        let original = try String(contentsOf: fixture.deck, encoding: .utf8)
        let source = original.replacingOccurrences(of: ".op\n", with: """
        .temp \(temperature) \(temperature + 1)
        .param family_bias={0.1+0.01*rand()+0.00001*temper}
        Vproof proof 0 {family_bias}
        Rproof proof 0 1k
        .mc 2 dc \(gate.id) \(gate.value) \(gate.value) 1e-5 seed=17

        """)
        try source.write(to: fixture.deck, atomically: true, encoding: .utf8)
        let completed = try await CoreSpicePreparedCommand(arguments: [fixture.deck.path,
            "--osdi-catalog", fixture.catalog.path, "--csv", fixture.csv.path]).executeWithRecord()
        let saved = fixture.root.appendingPathComponent("conditions.json")
        try Data(CoreSpiceCLIJSON.encode(completed.record).utf8).write(to: saved)
        let record = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(contentsOf: saved))
        #expect(record.schemaVersion == 6 && record.status == "succeeded")
        #expect(record.expectedCaseCount == 4 && record.temperatureCount == 2)
        let runs = try #require(record.cases)
        try #require(runs.count == 4)
        #expect(runs.map(\.selection.seed) == [17, 18, 17, 18])
        #expect(runs.map(\.selection.temperatureCelsius) == [temperature, temperature, temperature + 1, temperature + 1])
        #expect(runs.map(\.selection.temperatureIndex) == [0, 0, 1, 1])
        #expect(runs.map(\.selection.monteCarloIteration) == [0, 1, 0, 1])
        #expect(runs.allSatisfy { $0.selection.monteCarloIterations == 2 && $0.selection.monteCarloBaseSeed == 17
            && $0.selection.monteCarloSeedOrigin == "sourceDirective" })
        #expect(Set(runs.map(\.completion.configurationIdentity)).count == 4)
        #expect(runs.allSatisfy { $0.completion.sourceInputIdentity == record.sourceInputIdentity
            && $0.completion.points == 1 && $0.statistics.solveAttempts > 0 })
        let sourceReference = try CoreSpiceCLIArtifactReferencer().input(path: fixture.deck.path, kind: .netlist, format: .spice)
        #expect(completed.output.prepared.input.sources.map { $0.binding.reference } == [sourceReference])
        #expect(completed.output.sourceInputIdentity.hexadecimalValue == record.sourceInputIdentity)
        let artifacts = try #require(fixture.json["artifacts"] as? [[String: Any]])
        let expectedArtifacts = try artifacts.map { artifact in
            try JSONDecoder().decode(ArtifactReference.self,
                from: JSONSerialization.data(withJSONObject: try #require(artifact["reference"])))
        }
        for run in runs {
            #expect(run.waveform.analysis.rawValue == "dc")
            #expect(run.waveform.coordinates == [gate.value])
            #expect(run.waveform.imaginary == nil)
            let models = try #require(run.completion.osdiModels)
            #expect(models.count == point.input.devices.count)
            for device in point.input.devices {
                let model = try #require(models.first { $0.instanceName == "n_" + device.id.lowercased() })
                let library = try #require(manifest.libraries.first { $0.id == device.library })
                #expect(expectedArtifacts.contains(model.artifact))
                #expect(model.artifact.digest.hexadecimalValue == library.sha256)
                #expect(model.descriptorIndex == device.descriptorIndex && model.expectedDescriptorName == library.descriptorName)
                #expect(model.effectiveKelvin == run.selection.temperatureCelsius + 273.15)
                #expect(model.previousState == device.previousState)
                let models = try device.parameters.filter { $0.scope == "model" }.map { CoreSpiceCLIOSDIParameterRecord(try $0.assignment()) }
                let instances = try device.parameters.filter { $0.scope == "instance" }.map { CoreSpiceCLIOSDIParameterRecord(try $0.assignment()) }
                #expect(model.modelParameters == models && model.instanceParameters == instances)
                #expect(model.phase == "dc" && model.completedPointCount == 1)
                #expect(model.sourcePointIndex == 0 && model.sourceValueBits == gate.value.bitPattern)
                #expect(model.sourceName?.lowercased() == gate.id.lowercased())
            }
        }
        let proofs = try runs.map { run -> Double in
            let index = try #require(run.waveform.variables.firstIndex { $0.name.lowercased() == "v(proof)" })
            return run.waveform.real[index]
        }
        #expect(proofs[0] != proofs[1])
        #expect(abs((proofs[2] - proofs[0]) - 1e-5) < 1e-12)
        #expect(abs((proofs[3] - proofs[1]) - 1e-5) < 1e-12)
        let rows = try csvRows(fixture.csv)
        #expect(rows.count == runs.reduce(0) { $0 + $1.waveform.real.count })
        for run in runs {
            let selected = rows.filter { $0["case"] == String(run.index) }
            #expect(selected.count == run.waveform.real.count)
            for (index, row) in selected.enumerated() {
                #expect(row["seed"] == String(run.selection.seed))
                #expect(Double(try #require(row["temperature_celsius"])) == run.selection.temperatureCelsius)
                #expect(row["phase"] == "result" && row["analysis"] == "dc")
                #expect(row["variable"] == run.waveform.variables[index].name)
                let savedRealText = try #require(row["real"])
                let savedReal = try #require(Double(savedRealText))
                #expect(savedReal.bitPattern == run.waveform.real[index].bitPattern)
                #expect(Double(try #require(row["coordinate"])) == gate.value)
            }
        }
        let replay = try await CoreSpicePreparedCommand(arguments: [fixture.deck.path,
            "--osdi-catalog", fixture.catalog.path]).executeWithRecord()
        let repeated = try #require(replay.record.cases)
        try #require(repeated.count == runs.count)
        #expect(replay.record.configurationIdentity == record.configurationIdentity)
        for index in runs.indices {
            #expect(repeated[index].selection == runs[index].selection)
            #expect(repeated[index].completion.configurationIdentity == runs[index].completion.configurationIdentity)
            #expect(repeated[index].completion.sourceInputIdentity == runs[index].completion.sourceInputIdentity)
            #expect(repeated[index].completion.osdiModels == runs[index].completion.osdiModels)
            #expect(repeated[index].waveform.coordinates == runs[index].waveform.coordinates)
            #expect(repeated[index].waveform.real.map(\.bitPattern) == runs[index].waveform.real.map(\.bitPattern))
        }
    }

    private func csvRows(_ path: URL) throws -> [[String: String]] {
        let text = try String(contentsOf: path, encoding: .utf8)
        var records: [[String]] = [], fields: [String] = [], field = "", quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index], next = text.index(after: index)
            if character == "\"" {
                if quoted, next < text.endIndex, text[next] == "\"" { field.append("\""); index = text.index(after: next); continue }
                quoted.toggle()
            } else if character == "," && !quoted { fields.append(field); field = "" }
            else if character == "\n" && !quoted { fields.append(field); records.append(fields); fields = []; field = "" }
            else { field.append(character) }
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

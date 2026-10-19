import CoreSpiceIO
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite("Typed transfer-function persistence", .timeLimit(.minutes(2)))
struct TransferFunctionPersistenceTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tf-persistence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func cleanup(_ root: URL) {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("TF persistence cleanup failed: \(error)") }
    }
    private let finite = "TF finite\nV1 in 0 1\nR1 in out 1k\nR2 out 0 1k\n.tf V(out) V1\n.end\n"
    private let open = "TF open\nV1 in 0 1\nC1 in 0 1n\nR1 out 0 1k\n.tf V(out) V1\n.end\n"

    @Test func actualFiniteAndOpenPortsReloadWithoutNonfiniteCells() async throws {
        let root = try directory(); defer { cleanup(root) }
        for (index, text) in [finite, open].enumerated() {
            let deck = root.appendingPathComponent("deck-\(index).cir")
            try text.write(to: deck, atomically: true, encoding: .utf8)
            let output = try await CoreSpicePreparedCommand(arguments: [deck.path]).executeWithRecord()
            let record = try #require(output.record.cases?.first?.completion)
            let saved = try #require(record.transferFunction)
            let waveform = try #require(record.savedWaveform)
            #expect(record.schemaVersion == 7)
            #expect(saved.schemaVersion == 1)
            #expect(saved.input.classification == (index == 0 ? "finite" : "open_circuit"))
            #expect(saved.output.classification == "finite")
            let actual = try #require(output.output.tfResult)
            switch actual.inputPortImpedance {
            case .finite(let value): #expect(saved.input.valueBits == value.bitPattern)
            case .openCircuit: #expect(saved.input.valueBits == nil)
            }
            #expect(saved.gainBits == actual.gain.bitPattern)
            #expect(abs(actual.gain - (index == 0 ? 0.5 : 0)) < 1e-8)
            if case .finite(let value) = actual.outputPortImpedance {
                #expect(abs(value - (index == 0 ? 500 : 1000)) < 1e-5)
            }
            #expect(waveform.real.allSatisfy { $0.isFinite })
            #expect(waveform.variables.map(\.name) == (index == 0 ? ["gain", "Zin", "Zout"] : ["gain", "Zout"]))
            try saved.validateWaveform(waveform)
            let restored = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: JSONEncoder().encode(output.record))
            #expect(restored.cases?.first?.completion.transferFunction?.input == saved.input)
        }
    }

    @Test func missingOrAlteredTypedValuesFlagsAndColumnsCannotReload() async throws {
        let root = try directory(); defer { cleanup(root) }
        let deck = root.appendingPathComponent("deck.cir")
        try open.write(to: deck, atomically: true, encoding: .utf8)
        let family = try await CoreSpicePreparedCommand(arguments: [deck.path]).executeWithRecord().record
        let record = try #require(family.cases?.first?.completion)
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        func refuses(_ mutate: (inout [String: Any]) throws -> Void) throws {
            var object = original; try mutate(&object)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }
        try refuses { $0.removeValue(forKey: "transferFunction") }
        try refuses { object in
            var tf = try #require(object["transferFunction"] as? [String: Any])
            tf["schemaVersion"] = 99; object["transferFunction"] = tf
        }
        try refuses { object in
            var tf = try #require(object["transferFunction"] as? [String: Any])
            tf["gainBits"] = Double(1).bitPattern; object["transferFunction"] = tf
        }
        try refuses { object in
            var tf = try #require(object["transferFunction"] as? [String: Any])
            tf["input"] = ["classification": "finite", "valueBits": Double(0).bitPattern]; object["transferFunction"] = tf
        }
        try refuses { object in
            var tf = try #require(object["transferFunction"] as? [String: Any])
            tf["input"] = ["classification": "open_circuit", "valueBits": Double(0).bitPattern]; object["transferFunction"] = tf
        }
        try refuses { object in
            var waveform = try #require(object["savedWaveform"] as? [String: Any])
            waveform["options"] = ["input_port_impedance": "finite", "output_port_impedance": "finite"]
            object["savedWaveform"] = waveform
        }
        try refuses { object in
            var waveform = try #require(object["savedWaveform"] as? [String: Any])
            var variables = try #require(waveform["variables"] as? [[String: Any]])
            variables[1]["name"] = "Zin"; waveform["variables"] = variables; object["savedWaveform"] = waveform
        }
        var familyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(family)) as? [String: Any])
        var cases = try #require(familyObject["cases"] as? [[String: Any]])
        var waveform = try #require(cases[0]["waveform"] as? [String: Any])
        waveform["real"] = [0, 1]; cases[0]["waveform"] = waveform; familyObject["cases"] = cases
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: JSONSerialization.data(withJSONObject: familyObject))
        }
    }

    @Test func ordinaryBatchAndCaseShareExactTypedTFCompletion() async throws {
        let root = try directory(); defer { cleanup(root) }
        let deck = root.appendingPathComponent("deck.cir")
        try open.write(to: deck, atomically: true, encoding: .utf8)
        let caseRoot = root.appendingPathComponent("case")
        let args = ["-b", deck.path, "--json", "--case-output", caseRoot.path, "--case-id", "tf-open"]
        var session = try Session(policy: .developerV1())
        let batch = try await CLI(arguments: args).executeBatch(options: .init(arguments: args), session: &session)
        #expect(batch.schemaVersion.major == 7)
        let completion = try #require(batch.analysisCompletions?.first)
        let json = try #require(completion.preparedCompletionJSON)
        let nested = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: Data(json.utf8))
        #expect(nested.analysis == "tf")
        #expect(nested.transferFunction?.input.classification == "open_circuit")
        let bytes = try Data(contentsOf: caseRoot.appendingPathComponent("source-completion-0.json"))
        #expect(bytes == Data(json.utf8))
        _ = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: JSONEncoder().encode(batch))
    }
}

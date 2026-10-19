import CoreSpice
import CoreSpiceIO
import CoreSpiceWaveform
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite("Actual CLI coupled RC persistence", .timeLimit(.minutes(2)))
struct SparsePEXPersistenceTests {
    @Test(arguments: [".op", ".ac lin 3 1000 1000000", ".tran 1e-8 1e-6 0 1e-8"])
    func actualBatchAndPreparedSaveReloadAllValues(analysis: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sparse-pex-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Sparse PEX CLI cleanup failed: \(error)") }
        }
        let deck = directory.appendingPathComponent("coupled.cir")
        // One driven aggressor and one grounded driver expose coupling in every phase.
        let source = """
        Source-driven coupled RC persistence
        V1 a 0 AC 1 PWL(0 1 1e-7 1 2e-7 0 1e-6 0)
        V2 b 0 DC .25 AC 0
        R1 a x 1000
        R2 b y 2000
        R3 x 0 10000
        R4 y 0 20000
        C1 x 0 1e-9
        C2 y 0 2e-9
        CC x y 5e-10
        \(analysis)
        .end

        """
        try source.write(to: deck, atomically: true, encoding: .utf8)
        let batchCSV = directory.appendingPathComponent("batch.csv")
        let preparedCSV = directory.appendingPathComponent("prepared.csv")
        let arguments = ["-b", deck.path, "--csv", batchCSV.path, "--json"]
        var session = try Session(policy: .developerV1())
        let record = try await CLI(arguments: arguments).executeBatch(options: .init(arguments: arguments), session: &session)
        let recordFile = directory.appendingPathComponent("completed.json")
        try CoreSpiceCLIJSON.encode(record).write(to: recordFile, atomically: true, encoding: .utf8)
        let restored = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: Data(contentsOf: recordFile))
        #expect(restored == record)
        #expect(restored.solverIdentity == "CoreSpice.SparseLU.SwiftCSC.v2")
        let native = try await CoreSpicePreparedCommand(arguments: [deck.path, "--csv", preparedCSV.path, "--json"]).executeWithRecord()
        let reloadedNative = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self,
            from: Data(try CoreSpiceCLIJSON.encode(native.record).utf8))
        #expect(reloadedNative.solverIdentity == "CoreSpice.SparseLU.SwiftCSC.v2")
        #expect(reloadedNative.sourceInputIdentity == native.output.sourceInputIdentity.hexadecimalValue)
        #expect(reloadedNative.configurationIdentity == native.output.configurationIdentity.hexadecimalValue)
        #expect(native.output.prepared.solverIdentity == "CoreSpice.SparseLU.SwiftCSC.v2")
        #expect(restored.inputArtifacts.contains { $0.descriptor.kind == .netlist })
        let batch = try CSVWaveformReader().read(contentsOfFile: batchCSV.path)
        let prepared = try CSVWaveformReader().read(contentsOfFile: preparedCSV.path)
        let inMemory = try #require(session.lastWaveform)
        #expect(batch.pointCount == inMemory.pointCount)
        #expect(prepared.pointCount == native.output.waveform.pointCount)
        try compareEveryValue(batch, inMemory)
        try compareEveryValue(prepared, native.output.waveform)
        #expect(batch.variables.map(\.name) == prepared.variables.map(\.name))
        #expect(batch.pointCount == prepared.pointCount)
        // Every serialized value is checked within the existing CSV formatter precision, including both AC lanes.
        if analysis == ".op" {
            let x = try #require(batch.variables.firstIndex { $0.name.lowercased() == "v(x)" })
            let y = try #require(batch.variables.firstIndex { $0.name.lowercased() == "v(y)" })
            #expect(abs(try #require(batch.realValue(variable: x, point: 0)) - 10.0 / 11.0) < 1e-8)
            #expect(abs(try #require(batch.realValue(variable: y, point: 0)) - 2.5 / 11.0) < 1e-8)
        }
        if batch.isComplex {
            let y = try #require(batch.variables.firstIndex { $0.name.lowercased() == "v(y)" })
            #expect(try #require(batch.complexValue(variable: y, point: 0)).imag != 0)
        }
    }


    @Test func defaultCSVPrecisionAdmitsDecimalRoundingPlusBinaryParseULP() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sparse-csv-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("CSV boundary fixture cleanup failed: \(error)") }
        }
        let deck = directory.appendingPathComponent("boundary.cir")
        try "CSV decimal boundary\nV1 out 0 0\nI1 out 0 1.000287244593695e-6\n.op\n.end\n"
            .write(to: deck, atomically: true, encoding: .utf8)
        let preparedCSV = directory.appendingPathComponent("prepared.csv")
        let prepared = try await CoreSpicePreparedCommand(arguments: [deck.path, "--csv", preparedCSV.path, "--json"]).executeWithRecord()
        let apiPrepared = try SPICENativeSimulation().prepare(prepared.output.prepared.input, limits: prepared.output.prepared.limits)
        let api = try await SPICENativeSimulation().execute(apiPrepared, cancellation: .init())
        let apiCSV = directory.appendingPathComponent("api.csv")
        _ = try await SPICEIO.exportToCSV(api.waveform, path: apiCSV.path)
        #expect(api.sourceInputIdentity == prepared.output.sourceInputIdentity)
        #expect(api.configurationIdentity == prepared.output.configurationIdentity)
        let batchCSV = directory.appendingPathComponent("batch.csv")
        let arguments = ["-b", deck.path, "--csv", batchCSV.path, "--json"]
        var session = try Session(policy: .developerV1())
        _ = try await CLI(arguments: arguments).executeBatch(options: .init(arguments: arguments), session: &session)
        let batch = try #require(session.lastWaveform)
        let exact = -1.000287244593695e-6
        let rounded = -1.0002872445937e-6
        for (waveform, path) in [(api.waveform, apiCSV), (prepared.output.waveform, preparedCSV), (batch, batchCSV)] {
            let saved = try CSVWaveformReader().read(contentsOfFile: path.path)
            let variable = try #require(waveform.variables.firstIndex { $0.name.lowercased() == "i(v1)" })
            let actual = try #require(waveform.realValue(variable: variable, point: 0))
            let restored = try #require(saved.realValue(variable: variable, point: 0))
            #expect(actual.bitPattern == exact.bitPattern)
            #expect(restored.bitPattern == rounded.bitPattern)
            #expect(abs(restored - actual) > 5e-15 * abs(actual))
            #expect(abs(restored - actual) <= 5e-15 * abs(actual) + max(actual.ulp, restored.ulp))
            try compareEveryValue(saved, waveform)
        }
        #expect(withinDefaultCSVPrecision(0, 0))
        #expect(!withinDefaultCSVPrecision(Double.leastNonzeroMagnitude, 0))
    }

    private func withinDefaultCSVPrecision(_ saved: Double, _ actual: Double) -> Bool {
        actual == 0 ? saved == 0 : abs(saved - actual) <= 5e-15 * abs(actual) + max(actual.ulp, saved.ulp)
    }

    private func compareEveryValue(_ saved: WaveformData, _ actual: WaveformData) throws {
        #expect(saved.sweepValues.count == actual.sweepValues.count)
        for (lhs, rhs) in zip(saved.sweepValues, actual.sweepValues) {
            #expect(withinDefaultCSVPrecision(lhs, rhs))
        }
        #expect(saved.variables.map(\.name) == actual.variables.map(\.name))
        #expect(saved.isComplex == actual.isComplex)
        for variable in actual.variables.indices {
            for point in 0..<actual.pointCount {
                let lhs = try #require(saved.complexValue(variable: variable, point: point))
                let rhs = try #require(actual.complexValue(variable: variable, point: point))
                #expect(withinDefaultCSVPrecision(lhs.real, rhs.real))
                #expect(withinDefaultCSVPrecision(lhs.imag, rhs.imag))
            }
        }
    }
}

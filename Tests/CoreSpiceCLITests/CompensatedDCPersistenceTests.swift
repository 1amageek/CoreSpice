import CoreSpice
import CoreSpiceDevices
import CoreSpiceIR
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite("Actual CLI compensated DC persistence", .timeLimit(.minutes(1)))
struct CompensatedDCPersistenceTests {
    @Test(arguments: [0.9, -0.9])
    func batchAndPreparedReloadExactDecimalSweepEndpoint(stop: Double) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("decimal-dc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Temporary DC fixture cleanup failed: \(error)") }
        }
        let deck = root.appendingPathComponent("decimal.cir")
        let step = stop > 0 ? 0.3 : -0.3
        try "decimal endpoint\nV1 out 0 0\nR1 out 0 1k\n.dc V1 0 \(stop) \(step)\n.end\n"
            .write(to: deck, atomically: true, encoding: .utf8)
        let arguments = ["-b", deck.path, "--json"]
        var session = try Session(policy: .developerV1())
        let batch = try await CLI(arguments: arguments).executeBatch(options: .init(arguments: arguments), session: &session)
        let batchBytes = Data(try CoreSpiceCLIJSON.encode(batch).utf8)
        let batchReload = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: batchBytes)
        let prepared = try await CoreSpicePreparedCommand(arguments: [deck.path, "--json"]).executeWithRecord()
        let preparedBytes = Data(try CoreSpiceCLIJSON.encode(prepared.record).utf8)
        let preparedReload = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: preparedBytes)
        let expected = [0.0, step, 2 * step, stop].map(\.bitPattern)
        for saved in [batchReload.nativeDCResult, preparedReload.nativeDCResult] {
            let canonical = try #require(saved)
            #expect(canonical.coordinateBits == expected)
            #expect(canonical.points.count == expected.count)
        }
        #expect(batchReload.nativeDCResult == preparedReload.nativeDCResult)
    }

    @Test(arguments: [".op", ".dc V1 .5 .6 .1"])
    func batchAndPreparedSaveReloadCompletePairs(analysis: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paired-dc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Temporary DC fixture cleanup failed: \(error)") }
        }
        let deck = root.appendingPathComponent("nearshort.cir")
        try "near short\nV1 in 0 .5\nR1 in out 1u\nI1 out 0 10p\n.options reltol=1e-20 abstol=1p\n\(analysis)\n.end\n"
            .write(to: deck, atomically: true, encoding: .utf8)
        let arguments = ["-b", deck.path, "--json"]
        var session = try Session(policy: .developerV1())
        let batch = try await CLI(arguments: arguments).executeBatch(options: .init(arguments: arguments), session: &session)
        let savedBatch = try CoreSpiceCLIJSON.encode(batch)
        let path = root.appendingPathComponent("completed.json")
        try savedBatch.write(to: path, atomically: true, encoding: .utf8)
        let restored = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: Data(contentsOf: path))
        let canonical = try #require(restored.nativeDCResult)
        #expect(canonical == batch.nativeDCResult)
        #expect(restored.schemaVersion.major == 5 && restored.osdiExecution == nil)
        let prepared = try await CoreSpicePreparedCommand(arguments: [deck.path, "--json"]).executeWithRecord()
        let preparedBytes = Data(try CoreSpiceCLIJSON.encode(prepared.record).utf8)
        let preparedReload = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: preparedBytes)
        #expect(preparedReload.schemaVersion == 5 && preparedReload.osdiExecution == nil)
        #expect(preparedReload.nativeDCResult == prepared.output.storedDCResult)
        #expect(preparedReload.nativeDCResult == canonical)
        let plan = try #require(session.plan)
        let input = try #require(plan.ir.nodeNames.first { $0.value == "in" }?.key)
        let output = try #require(plan.ir.nodeNames.first { $0.value == "out" }?.key)
        for index in canonical.points.indices {
            let point = try canonical.result(at: index)
            let drop = try CompensatedEnclosure(center: point.checkedCompensatedVoltage(at: input))
                .subtracting(CompensatedEnclosure(center: point.checkedCompensatedVoltage(at: output)))
            let current = try drop.multiplied(by: CompensatedEnclosure(center: CompensatedValue(high: 1e6)))
            #expect(try current.subtracting(CompensatedEnclosure(center: CompensatedValue(high: 1e-11))).absoluteUpperBound <= 1e-12)
            #expect(try point.checkedCompensatedVoltage(at: output).low != 0)
        }
        var malformed = try #require(JSONSerialization.jsonObject(with: Data(savedBatch.utf8)) as? [String: Any])
        malformed.removeValue(forKey: "nativeDCResult")
        #expect(throws: SPICENativeStoredDCResult.Failure.self) {
            _ = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: JSONSerialization.data(withJSONObject: malformed))
        }
    }
}

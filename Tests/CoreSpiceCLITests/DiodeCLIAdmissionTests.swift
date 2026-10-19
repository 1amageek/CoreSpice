import Foundation
import Testing
import ToolQualification
import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceDiodeContracts
import CoreSpiceDevices
@testable import CoreSpiceCLICore

@Suite("Diode CLI admission", .timeLimit(.minutes(1)))
struct DiodeCLIAdmissionTests {
    private func directory() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("diode-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: false)
        return url
    }
    private func cleanup(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Fixture cleanup failed: \(error)") }
    }
    @Test func ordinaryAndPreparedActuallyExecuteSupportedDiode() async throws {
        let root=try directory(); defer { cleanup(root) }
        let deck=root.appendingPathComponent("deck.cir")
        try "diode\n.model dmod d is=1e-14 cjo=1p tt=1n bv=5 ibv=1m\nV1 in 0 1\nR1 in out 1k\nD1 out 0 dmod\n.op\n.end\n".write(to: deck,atomically: true,encoding: .utf8)
        var session=try Session(policy: .developerV1())
        try await session.loadNetlist(source: String(contentsOf: deck,encoding: .utf8),fileName: deck.path)
        let waveform=try await session.run(.op)
        #expect(waveform.pointCount==1)
        let output=try await CoreSpicePreparedCommand(arguments: [deck.path]).execute()
        #expect(output.waveform.pointCount==1 && output.executedModels.contains { $0.deviceType=="diode" })
    }
    @Test func originalCaseReloadHasCurrentMetricDefinitionLinks() async throws {
        let root=try directory(); defer { cleanup(root) }
        let deck=root.appendingPathComponent("resistor.cir"), output=root.appendingPathComponent("case")
        try "original\nV1 out 0 1\nR1 out 0 1k\n.op\n.end\n".write(to: deck,atomically: true,encoding: .utf8)
        let args=["-b",deck.path,"--case-output",output.path,"--case-id","metric-definition","--json"]
        var session=try Session(policy: .developerV1())
        _=try await CLI(arguments: args).executeBatch(options: .init(arguments: args),session: &session)
        let execution=try ToolQualificationCaseExecution.decodeCanonical(from: Data(contentsOf: output.appendingPathComponent("execution.json")))
        #expect(Set(execution.metricDefinitionArtifacts.keys)==Set(execution.observedMetrics.keys))
    }

    @Test func roleSeparatedCompletedRecordsReloadWithoutChangingNumericalInput() async throws {
        let root=try directory(); defer { cleanup(root) }
        let deck=root.appendingPathComponent("roles.cir")
        try "roles\n.options temp=40 tnom=35\n.model dm d is=1e-14 m=.4 cjo=1p\nV1 in 0 1\nR1 in out 1k\nD1 out 0 dm area=3 m=2 temp=77\n.op\n.end\n".write(to: deck,atomically: true,encoding: .utf8)
        let args=["-b",deck.path,"--json"]
        var session=try Session(policy: .developerV1())
        let record=try await CLI(arguments: args).executeBatch(options: .init(arguments: args),session: &session)
        let encoded=try JSONEncoder().encode(record)
        let decoded=try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self,from: encoded)
        let diode=try #require(decoded.diodeModels.first)
        #expect(decoded.schemaVersion == .v3 && decoded.diodeResolutionProfile=="genericDiodeV1")
        #expect(diode.modelParameters["m"]==0.4 && diode.instanceParameters["m"]==2)
        #expect(diode.instanceParameters["area"]==3 && abs(diode.effectiveKelvin-350.15)<1e-12)
        #expect(diode.captureID != nil && diode.coldSetupCount==1 && diode.orderedAssignmentEvidence)
        let output=try await CoreSpicePreparedCommand(arguments: [deck.path,"--json"]).execute()
        let prepared=try CoreSpiceCLIPreparedRunRecord(output)
        let reloaded=try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self,from: JSONEncoder().encode(prepared))
        #expect(reloaded.diodeModels.count==1 && reloaded.configurationIdentity==prepared.configurationIdentity)
        var invalid=try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared)) as? [String: Any])
        invalid["schemaVersion"]=99
        #expect(throws: DecodingError.self) { _=try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self,from: JSONSerialization.data(withJSONObject: invalid)) }
    }
    @Test func unsupportedInputsAndExplicitCoreRefusalNeverPublishCompletedCase() async throws {
        for (model,extra) in [("rs=1000",[String]()),("cjo=1p",["--diode-profile","coreDiodeV1"]),("level=3",[String]())] {
            let root=try directory(); defer { cleanup(root) }
            let deck=root.appendingPathComponent("unsupported.cir"), output=root.appendingPathComponent("case")
            try "unsupported\n.model dm d \(model)\nV1 out 0 .1\nD1 out 0 dm\n.op\n.end\n".write(to: deck,atomically: true,encoding: .utf8)
            let args=["-b",deck.path,"--case-output",output.path,"--case-id","unsupported","--json"]+extra
            var session=try Session(policy: .developerV1(diodeProfile: extra.isEmpty ? .genericDiodeV1 : .coreDiodeV1))
            do { _=try await CLI(arguments: args).executeBatch(options: .init(arguments: args),session: &session); Issue.record("Unsupported diode completed") }
            catch { #expect(CoreSpiceCLIFailure(error: error).code.hasPrefix("diode.")) }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
        for args in [["-b","deck","--diode-profile","wrong"],["-b","deck","--diode-profile","coreDiodeV1","--diode-profile","genericDiodeV1"]] {
            #expect(throws: CLIError.self) { _=try CoreSpiceBatchOptions(arguments: args) }
        }
    }
    @Test func diodeCasePublishesExactConsumedModelAndCurrentDefinitions() async throws {
        let root=try directory(); defer { cleanup(root) }
        let deck=root.appendingPathComponent("diode.cir"), output=root.appendingPathComponent("case")
        try "case\n.model dm d is=1e-14 m=.4 cjo=1p\nV1 in 0 1\nR1 in out 1k\nD1 out 0 dm area=3 m=2\n.op\n.end\n".write(to: deck,atomically: true,encoding: .utf8)
        let args=["-b",deck.path,"--case-output",output.path,"--case-id","diode-case","--json"]
        var session=try Session(policy: .developerV1())
        _=try await CLI(arguments: args).executeBatch(options: .init(arguments: args),session: &session)
        let receipt=try ToolQualificationModelExecutionReceipt.decodeCanonical(from: Data(contentsOf: output.appendingPathComponent("model-receipt-0.json")))
        #expect(receipt.selectedModelIdentifier=="dm" && receipt.resolvedParameters["m"]==0.4)
        let consumed=try #require(receipt.consumedInstances["d1"])
        #expect(consumed["m"]==2 && consumed["area"]==3)
        let execution=try ToolQualificationCaseExecution.decodeCanonical(from: Data(contentsOf: output.appendingPathComponent("execution.json")))
        #expect(execution.schemaVersion==3 && !execution.metricDefinitionArtifacts.isEmpty)
        let definitions=try FileManager.default.contentsOfDirectory(at: output,includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("metric-definition-") }
        #expect(definitions.count==execution.observedMetrics.count)
        for file in definitions {
            let definition=try ToolQualificationMetricDefinition.decodeCanonical(from: Data(contentsOf: file))
            #expect(execution.metricDefinitionArtifacts[definition.metricID] != nil)
            #expect(definition.extractionID.hasPrefix("CoreSpice.final-phase-sample."))
        }
    }
    @Test func poleZeroCaseUsesActualTypedValuesAndRejectsNonfiniteObservations() async throws {
        let root=try directory(); defer { cleanup(root) }
        let deck=root.appendingPathComponent("pole-zero.cir"), output=root.appendingPathComponent("case")
        try "pz\n.model dm d is=1e-14 cjo=1p\nV1 in 0 dc .7 ac 1\nR1 in out 1k\nD1 out 0 dm\n.pz in 0 out 0 vol pz\n.end\n".write(to: deck,atomically: true,encoding: .utf8)
        let args=["-b",deck.path,"--json","--case-output",output.path,"--case-id","pz"]
        var session=try Session(policy: .developerV1())
        _=try await CLI(arguments: args).executeBatch(options: .init(arguments: args),session: &session)
        let execution=try ToolQualificationCaseExecution.decodeCanonical(from: Data(contentsOf: output.appendingPathComponent("execution.json")))
        #expect(execution.observedMetrics["pz:dc-gain"] != nil)
        #expect(execution.observedMetrics.keys.contains { $0.hasPrefix("pz:pole:") })
        #expect(!execution.observedMetrics.keys.contains { $0.hasPrefix("pz:zero:") })
        #expect(execution.observedMetrics.values.allSatisfy { $0.isFinite })
        #expect(Set(execution.metricDefinitionArtifacts.keys)==Set(execution.observedMetrics.keys))
        let domain=try JSONDecoder().decode([String: CoreSpiceCLIMetricSemantics].self,from: Data(contentsOf: output.appendingPathComponent("metric-domain.json")))
        #expect(domain["pz:pole:0:real"]?.declaredUnit=="rad/s")
        #expect(domain.values.allSatisfy { $0.extractionID=="CoreSpice.pole-zero.indexed-value.v1" })
        for invalid in [Double.nan,Double.infinity,-Double.infinity] {
            #expect(throws: CoreSpiceCLICaseError.self) {
                _=try CoreSpiceCLIMetricObservation(name: "pole:0:real",value: invalid,meaning: .poleZero(name: "pole:0:real"))
            }
            #expect(throws: AnalysisResultValidationError.self) {
                _=try PoleZeroResult(poles: [.init(real: invalid)],zeros: [],dcGain: 1,variableMap: [:])
            }
        }
    }

}

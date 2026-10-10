import Foundation
import CoreSpiceDevices
import CoreSpiceCompactModels
import Testing
@testable import CoreSpiceCLICore

@Suite("BSIM4 CLI execution policy and qualification", .timeLimit(.minutes(1)))
struct BSIM4ProductionRecordTests {
    private func source(policy: String = ".options bsim4stressiterations=8", paramchk: Int = 1, analysis: String = ".op") -> String {
        """
        Explicit native BSIM4 caller
        \(policy)
        .model process nmos level=54 version=4.8.3 vth0=0.7 u0=0.05 toxe=10n tnoimod=1 paramchk=\(paramchk)
        VD d 0 1
        VG g 0 1.2 ac 1
        VS s 0 0
        VB b 0 -0.1
        M1 d g s b process l=1u w=10u rbodymod=1 rgatemod=3 trnqsmod=1 acnqsmod=1
        \(analysis)
        .end
        """
    }
    private func run(_ text: String) async throws -> CoreSpiceCLIBatchRunRecord {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("corespice-bsim4-\(UUID().uuidString).cir")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer {
            do { try FileManager.default.removeItem(at: url) }
            catch { Issue.record("Temporary deck cleanup failed: \(error)") }
        }
        let arguments = ["-b", url.path, "--json"]
        var session = try Session(policy: .developerV1())
        return try await CLI(arguments: arguments).executeBatch(options: CoreSpiceBatchOptions(arguments: arguments), session: &session)
    }
    @Test func actualBatchPreservesEffectivePolicyAndModeQualification() async throws {
        for paramchk in [0, 1] {
            let record = try await run(source(paramchk: paramchk))
            #expect(record.status == "succeeded")
            #expect(record.bsim4PreparationPolicy?.maximumStressIterations == 8)
            let model = try #require(record.bsim4Models.first)
            #expect(model.device == "m1")
            #expect(model.phase == "op")
            #expect(model.maintainerUnsupportedNoiseMode)
            #expect(model.diagnostics.contains { $0.code == .maintainerNoiseModeLimitation } == (paramchk == 1))
            let roundTrip = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: JSONEncoder().encode(record))
            #expect(roundTrip.bsim4PreparationPolicy == record.bsim4PreparationPolicy)
            #expect(roundTrip.bsim4Models == record.bsim4Models)
        }
    }
    @Test func actualSourceSweepsRetainPreparationPolicy() async throws {
        for analysis in [".dc VG 1.0 1.2 0.1", ".mc 2 dc VG 1.0 1.2 0.1"] {
            let text = source(analysis: analysis).replacingOccurrences(of:
                " rbodymod=1 rgatemod=3 trnqsmod=1 acnqsmod=1", with: "")
            let record = try await run(text)
            #expect(record.status == "succeeded")
            #expect(record.bsim4PreparationPolicy?.maximumStressIterations == 8)
            #expect(record.bsim4Models.count == (analysis.contains(".mc") ? 6 : 3))
            #expect((record.waveform?.points ?? 0) > 0)
            if analysis.contains(".mc") { #expect(record.waveform?.runs == 2) }
        }
    }
    @Test func actualBatchTypedFailuresDoNotBecomeSuccess() async throws {
        for (text, code) in [
            (source(policy: ""), "device.bsim4.missing-preparation-policy"),
            (source(policy: ".options bsim4stressiterations=0"), "deck.analysis-options"),
            (source().replacingOccurrences(of: "version=4.8.3", with: "version=4.8.2"), "mos.resolution"),
            (source(analysis: ".noise V(d) VG dec 1 1k 1Meg").replacingOccurrences(of: "toxe=10n", with: "toxe=10n fnoimod=0 kf=-1").replacingOccurrences(of: "VD d 0 1", with: "VD supply 0 1\nRL supply d 1k"), "device.bsim4.non-finite")
        ] {
            do { _ = try await run(text); Issue.record("Failed input produced success") }
            catch {
                let failure = CoreSpiceCLIFailure(error: error)
                #expect(failure.status == "failed")
                #expect(failure.code == code, "Actual error: \(error)")
            }
        }
    }
    @Test func actualNoiseAndMonteCarloBindingRetainTopologyIntent() async throws {
        for analysis in [".noise V(d) VG dec 1 1k 1Meg", ".noise V(d) VG dec 1 1k 1Meg\n.mc 2 dc VG 1.0 1.2 0.1"] {
            for paramchk in [0, 1] {
                let text = source(paramchk: paramchk, analysis: analysis)
                    .replacingOccurrences(of: "VD d 0 1", with: "VD supply 0 1\nRL supply d 1k")
                let record = try await run(text)
                #expect(record.status == "succeeded")
                #expect(record.bsim4NoisePreparationRequested)
                #expect(record.bsim4PreparationPolicy?.maximumStressIterations == 8)
                let model = try #require(record.bsim4Models.first)
                #expect(model.maintainerUnsupportedNoiseMode)
                #expect(model.diagnostics.contains { $0.code == .maintainerNoiseModeLimitation } == (paramchk == 1))
                #expect((record.waveform?.points ?? 0) == (analysis.contains(".mc") ? 3 : 4))
                if analysis.contains(".mc") { #expect(record.waveform?.runs == 2) }
                let data = try JSONEncoder().encode(record)
                #expect(try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: data).bsim4NoisePreparationRequested)
            }
        }
    }

}

@Suite("CLI refuses stale MOS sensitivity", .timeLimit(.minutes(1)))
struct MOSCLISensitivityTests {
    @Test func dcAndACSensitivityRequireFreshResolution() async throws {
        for directive in [".sens V(d)", ".sens V(d) ac dec 1 1k 1Meg"] {
            var session = try Session(policy: .developerV1())
            try await session.loadNetlist(source: """
            Fresh MOS sensitivity
            .model n nmos level=1 vto=.5 kp=1m
            VG g 0 1
            VD d 0 1
            M1 d g 0 0 n l=1u w=2u
            \(directive)
            .end
            """, fileName: nil)
            do {
                _ = try await session.runParsed(session.requiredDefaultRunnableAnalysis())
                Issue.record("MOS sensitivity reused resolved values")
            } catch {
                #expect(CoreSpiceCLIFailure(error: error).code == "analysis.requires-fresh-mos-resolution")
                #expect(session.lastWaveform == nil)
            }
        }
    }
}

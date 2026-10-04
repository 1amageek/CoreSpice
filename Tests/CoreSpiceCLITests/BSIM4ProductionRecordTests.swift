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
        var session = Session()
        return try await CLI(arguments: arguments).executeBatch(options: CoreSpiceBatchOptions(arguments: arguments), session: &session)
    }
    @Test func actualBatchPreservesEffectivePolicyAndModeQualification() async throws {
        for paramchk in [0, 1] {
            let record = try await run(source(paramchk: paramchk))
            #expect(record.status == "succeeded")
            #expect(record.bsim4PreparationPolicy?.maximumStressIterations == 8)
            let model = try #require(record.bsim4Models.first)
            #expect(model.device == "m1")
            #expect(model.phase == "initial_binding")
            #expect(model.maintainerUnsupportedNoiseMode)
            #expect(model.diagnostics.contains { $0.code == .maintainerNoiseModeLimitation } == (paramchk == 1))
            let roundTrip = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self, from: JSONEncoder().encode(record))
            #expect(roundTrip.bsim4PreparationPolicy == record.bsim4PreparationPolicy)
            #expect(roundTrip.bsim4Models == record.bsim4Models)
        }
    }
    @Test func actualRepeatedBindingRetainsPolicy() async throws {
        for analysis in [".dc VG 1.0 1.2 0.1", ".mc 2 dc VG 1.0 1.2 0.1", ".sens V(d)", ".sens V(d) ac dec 1 1k 1Meg"] {
            // Sensitivity perturbs continuous parameters; selector flags are
            // intentionally absent, so discrete modes cannot be differentiated.
            let text = source(analysis: analysis).replacingOccurrences(of:
                " rbodymod=1 rgatemod=3 trnqsmod=1 acnqsmod=1", with: "")
            let record = try await run(text)
            #expect(record.status == "succeeded")
            #expect(record.bsim4PreparationPolicy?.maximumStressIterations == 8)
            #expect(record.bsim4Models.count == 1)
            #expect((record.waveform?.points ?? 0) > 0)
            if analysis.hasPrefix(".mc") { #expect(record.waveform?.runs == 2) }
        }
    }
    @Test func actualBatchTypedFailuresDoNotBecomeSuccess() async throws {
        for (text, code) in [
            (source(policy: ""), "device.bsim4.missing-preparation-policy"),
            (source(policy: ".options bsim4stressiterations=0"), "deck.blocked-intent"),
            (source().replacingOccurrences(of: "version=4.8.3", with: "version=4.8.2"), "deck.blocked-intent"),
            (source(analysis: ".noise V(d) VG dec 1 1k 1Meg"), "device.bsim4.unsupported-analysis")
        ] {
            do { _ = try await run(text); Issue.record("Failed input produced success") }
            catch {
                let failure = CoreSpiceCLIFailure(error: error)
                #expect(failure.status == "failed")
                #expect(failure.code == code, "Actual error: \(error)")
            }
        }
    }
}

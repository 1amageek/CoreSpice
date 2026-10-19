import CoreSpice
import CoreSpiceIO
import Foundation
import Testing
@testable import CoreSpiceCLICore

@Suite("Explicit CLI execution profile", .timeLimit(.minutes(2)))
struct ExecutionProfileTests {
    // These are caller-selected fixture ceilings, not a deployment sizing recommendation.
    private func fields(elements: Int = 20_000) -> [String: Any] {
        ["schemaVersion": 1, "maximumElements": elements,
         "maximumNativeAllocationBytes": 1024 * 1024 * 1024,
         "maximumLiveOwnedBytes": 4 * 1024 * 1024 * 1024,
         "maximumTemporaryBytes": 1024 * 1024 * 1024,
         "maximumHashedBytes": 64 * 1024 * 1024,
         "maximumSourceBytes": 8 * 1024 * 1024,
         "maximumPreparationWorkUnits": 100_000_000_000_000,
         "maximumResolutionRetainedBytes": 512 * 1024 * 1024]
    }

    private func decode(_ values: [String: Any]) throws -> CoreSpiceCLIExecutionProfile {
        try JSONDecoder().decode(CoreSpiceCLIExecutionProfile.self,
            from: JSONSerialization.data(withJSONObject: values))
    }

    @Test func closedSchemaRejectsUnknownMissingNonpositiveAndOverflowingValues() throws {
        let valid = try decode(fields())
        #expect(valid.maximumElements == 20_000)
        for key in fields().keys {
            var missing = fields(); missing.removeValue(forKey: key)
            #expect(throws: (any Error).self) { try decode(missing) }
            var zero = fields(); zero[key] = 0
            #expect(throws: (any Error).self) { try decode(zero) }
            var negative = fields(); negative[key] = -1
            #expect(throws: (any Error).self) { try decode(negative) }
            var fraction = fields(); fraction[key] = 1.5
            #expect(throws: (any Error).self) { try decode(fraction) }
        }
        var unknown = fields(); unknown["automaticRAMFraction"] = 0.5
        #expect(throws: CoreSpiceCLIExecutionProfile.Failure.self) { try decode(unknown) }
        var overflowing = fields(); overflowing["maximumElements"] = Int.max
        #expect(throws: CoreSpiceCLIExecutionProfile.Failure.self) { try decode(overflowing) }
        overflowing = fields(); overflowing["maximumNativeAllocationBytes"] = UInt64.max
        #expect(throws: CoreSpiceCLIExecutionProfile.Failure.self) { try decode(overflowing) }
    }

    @Test func profileFileIsBoundedAndOptionsRejectDuplicateOrMissingFlags() throws {
        #expect(throws: CLIError.self) { try CoreSpiceBatchOptions(arguments: ["-b", "deck.cir", "--execution-profile"]) }
        #expect(throws: CLIError.self) {
            try CoreSpiceBatchOptions(arguments: ["-b", "deck.cir", "--execution-profile", "a.json", "--execution-profile", "b.json"])
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("profile-bound-\(UUID().uuidString).json")
        defer { do { try FileManager.default.removeItem(at: path) } catch { Issue.record("Profile fixture cleanup failed") } }
        try Data(repeating: 32, count: 64 * 1024 + 1).write(to: path)
        #expect(throws: (any Error).self) { try CoreSpiceCLIExecutionProfile.load(path: path.path) }
    }

    @Test func selectedPolicyKeepsOneCumulativeOwnerAndRefusesPrecisionBudgetConflict() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Profile fixture cleanup failed") } }
        let path = directory.appendingPathComponent("profile.json")
        var values = fields(); values["maximumPreparationWorkUnits"] = 10
        try JSONSerialization.data(withJSONObject: values).write(to: path)
        let selected = try CoreSpiceCLIExecutionProfile.load(path: path.path)
        let defaultPolicy = try CoreSpiceCLIExecutionPolicy.developerV1()
        #expect(defaultPolicy.maximumElements == 8192 && defaultPolicy.executionProfile == nil)
        let policy = try defaultPolicy.applying(selected.profile, reference: selected.reference)
        let first = try policy.resources(), second = try policy.resources()
        #expect(first === second)
        try first.charge(.retainedElements, units: 6)
        #expect(throws: SPICESimulationResources.ResourceError.self) { try second.charge(.retainedElements, units: 5) }
        #expect(policy.numericalLimits == defaultPolicy.numericalLimits)
        #expect(policy.executionProfile == selected.profile)
        let precision = CoreSpiceCLIPrecisionExecutionBudget(maximumNativeAllocationBytes: 1024,
            maximumLiveOwnedBytes: 1024, maximumTemporaryBytes: 1024,
            maximumHashedBytes: 1024, maximumEvidenceBytes: 1024)
        #expect(throws: CoreSpiceCLIExecutionProfile.Failure.self) { try policy.applying(precision) }
        #expect(throws: CoreSpiceCLIExecutionProfile.Failure.self) {
            try defaultPolicy.applying(precision).applying(selected.profile, reference: selected.reference)
        }
        #expect(throws: CoreSpiceCLIExecutionProfile.Failure.self) {
            try CoreSpiceCLIExecutionProfile.validateSaved(selected.profile, reference: selected.reference, hasPrecisionBudget: true)
        }
    }

    @Test func explicitSourceCeilingControlsPreparedReadAndBatchCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Source profile fixture cleanup failed") } }
        let deck = directory.appendingPathComponent("padded.cir")
        let profile = directory.appendingPathComponent("profile.json")
        var source = "Explicit large source admission\n"
        source += "*" + String(repeating: "x", count: 1024 * 1024) + "\n"
        source += "I1 out 0 -.001\nR1 out 0 1k\n.op\n.end\n"
        try source.write(to: deck, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: fields()).write(to: profile)
        do {
            _ = try await CoreSpicePreparedCommand(arguments: [deck.path]).executeWithRecord()
            Issue.record("Default prepared source ceiling was silently enlarged")
        } catch { #expect(!(error is CancellationError)) }
        let completed = try await CoreSpicePreparedCommand(arguments: [deck.path, "--execution-profile", profile.path]).executeWithRecord()
        #expect(completed.output.waveform.pointCount == 1)
        var low = fields(); low["maximumSourceBytes"] = 1024
        try JSONSerialization.data(withJSONObject: low).write(to: profile)
        let arguments = ["-b", deck.path, "--execution-profile", profile.path]
        var session = try Session(policy: .developerV1())
        do {
            _ = try await CLI(arguments: arguments).executeBatch(options: .init(arguments: arguments), session: &session)
            Issue.record("Batch capture ignored caller source byte ceiling")
        } catch SPICESourceCaptureError.totalByteLimitExceeded(let limit, let requested) {
            #expect(limit == 1024 && requested > limit)
        }
    }

    @Test func actualLargeBatchAndPreparedRequireExplicitProfileAndReloadExactValues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-large-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Large profile fixture cleanup failed") } }
        let deck = directory.appendingPathComponent("diagonal.cir")
        let profile = directory.appendingPathComponent("profile.json")
        let lowProfile = directory.appendingPathComponent("low.json")
        var text = "Large source-driven diagonal admission\n"
        for index in 0..<4500 {
            text += "R\(index) n\(index) 0 1k\nI\(index) n\(index) 0 -.001\n"
        }
        text += ".options tranmaxaccepted=16 tranmaxattempts=64 tranmaxiterations=256 tranmaxscalars=100000 tranmaxdimension=5000 tranmaxwork=1000000000 tranmaxbreakpoints=16\n.op\n.end\n"
        try text.write(to: deck, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: fields()).write(to: profile)
        try JSONSerialization.data(withJSONObject: fields(elements: 100)).write(to: lowProfile)
        for flag in [[], ["--execution-profile", lowProfile.path]] {
            do {
                _ = try await CoreSpicePreparedCommand(arguments: [deck.path] + flag).executeWithRecord()
                Issue.record("Prepared large deck exceeded selected element ceiling")
            } catch { #expect(!(error is CancellationError)) }
            let arguments = ["-b", deck.path, "--json"] + flag
            var session = try Session(policy: .developerV1())
            do {
                _ = try await CLI(arguments: arguments).executeBatch(options: .init(arguments: arguments), session: &session)
                Issue.record("Batch large deck exceeded selected element ceiling")
            } catch { #expect(!(error is CancellationError)) }
        }
        // MOS construction charges each admitted COW-capacity copy to cumulative work.
        // The prior 10b fixture ceiling must remain an observable work refusal.
        let workProfile = directory.appendingPathComponent("work-limited.json")
        var limitedWork = fields(); limitedWork["maximumPreparationWorkUnits"] = 10_000_000_000
        try JSONSerialization.data(withJSONObject: limitedWork).write(to: workProfile)
        let limitedArguments = ["-b", deck.path, "--json", "--execution-profile", workProfile.path]
        var limitedSession = try Session(policy: .developerV1())
        do {
            _ = try await CLI(arguments: limitedArguments).executeBatch(options: .init(arguments: limitedArguments), session: &limitedSession)
            Issue.record("Large source ignored the cumulative preparation-work ceiling")
        } catch let failure as SPICESimulationPreparationError {
            guard case .resolution(let resolution, let cause) = failure,
                  let cause, case SPICESimulationResources.ResourceError.workLimit = cause else { throw failure }
            #expect(resolution == .limitExceeded(.retainedBytes))
            #expect(CoreSpiceCLIFailure(error: failure).code == "invocation.work-limit")
        }
        let selected = try CoreSpiceCLIExecutionProfile.load(path: profile.path)
        let arguments = ["-b", deck.path, "--json", "--execution-profile", profile.path]
        var session = try Session(policy: .developerV1())
        let batch = try await CLI(arguments: arguments).executeBatch(options: .init(arguments: arguments), session: &session)
        let restored = try JSONDecoder().decode(CoreSpiceCLIBatchRunRecord.self,
            from: Data(try CoreSpiceCLIJSON.encode(batch).utf8))
        #expect(restored.executionProfile == selected.profile)
        #expect(restored.executionProfileReference == selected.reference)
        #expect(restored.inputArtifacts.contains(selected.reference))
        #expect(restored.solverIdentity == "CoreSpice.SparseLU.SwiftCSC.v2")
        let prepared = try await CoreSpicePreparedCommand(arguments: [deck.path, "--execution-profile", profile.path]).executeWithRecord()
        let saved = try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self,
            from: Data(try CoreSpiceCLIJSON.encode(prepared.record).utf8))
        #expect(saved.executionProfile == selected.profile && saved.executionProfileReference == selected.reference)
        #expect(saved.configurationIdentity == prepared.output.configurationIdentity.hexadecimalValue)
        #expect(prepared.output.operatingPoint?.variables.count == 4500)
        #expect(prepared.output.operatingPoint?.variables.allSatisfy { abs($0 - 1) < 1e-8 } == true)
        var incomplete = try #require(JSONSerialization.jsonObject(with: Data(try CoreSpiceCLIJSON.encode(prepared.record).utf8)) as? [String: Any])
        incomplete.removeValue(forKey: "executionProfileReference")
        let incompleteData = try JSONSerialization.data(withJSONObject: incomplete)
        #expect(throws: CoreSpiceCLIExecutionProfile.Failure.self) {
            try JSONDecoder().decode(CoreSpiceCLIPreparedRunRecord.self, from: incompleteData)
        }
    }
}

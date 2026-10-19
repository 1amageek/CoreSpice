import CoreSpiceIO
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

@Suite("Legacy native MOS migration", .timeLimit(.minutes(1)))
struct LegacyNativeMOSMigrationTests {
    @Test(arguments: [49, 54])
    func legacyCardsAreBlockedAndPreserveSourceInsteadOfFallingBack(level: Int) async throws {
        let parsed = try await SPICEIO.parse("Migration\n.model old nmos level=\(level)\nM1 d g 0 0 old l=1u w=1u\n.end\n",
                                            fileName: "legacy.cir").get()
        let report = SPICEDeckCoverageReport.generate(from: parsed)
        let item = try #require(report.items.first { $0.name == "model:old" && $0.kind == .model })
        #expect(item.status == .blocked && item.message.contains("OSDI"))
        #expect(item.location?.line == 2)
        for profile in MOSInputProfile.allCases {
            do {
                _ = try SPICEIO.lower(parsed, profile: profile, seed: 42, limits: IOTestFrontend.limits)
                Issue.record("Legacy card fell back to a classical native model")
            } catch let error as MOSResolutionFailure {
                guard case .osdiBindingRequired(let refusedLevel, let version, let source) = error else {
                    Issue.record("Expected OSDI migration failure, received \(error)"); continue
                }
                #expect(refusedLevel == level && version == nil)
                #expect(source.path == "legacy.cir" && source.line == 2)
            }
        }
    }

    @Test func obsoleteStressOptionRefusesWithoutEvaluatingItsExpression() async throws {
        let parsed = try await SPICEIO.parse("Obsolete option\n.options bsim4stressiterations={missing+rand()}\nR1 d 0 1k\n.end\n").get()
        let compiled = try NetlistLowering.compile(parsed, limits: IOTestFrontend.limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1,
                                                         limits: IOTestFrontend.limits, seed: 42)
        do {
            _ = try SPICEAnalysisOptions.resolve(from: compiled, session: &session)
            Issue.record("Obsolete preparation policy was silently accepted")
        } catch let error as SPICEAnalysisOptionError {
            guard case .unsupportedOptionValue(let name, _, let reason) = error else {
                Issue.record("Expected unsupported-option migration failure, received \(error)"); return
            }
            #expect(name == "bsim4stressiterations" && reason.contains("OSDI"))
        }
        #expect(session.circuit == nil)
        let report = SPICEDeckCoverageReport.generate(from: parsed)
        #expect(report.items.first { $0.name == "bsim4stressiterations" }?.status == .blocked)
    }
}

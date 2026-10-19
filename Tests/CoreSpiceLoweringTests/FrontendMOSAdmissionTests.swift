import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParsedIR
import CoreSpiceParser
import CoreSpiceParserSPICE
import Testing

@Suite("MOS source admission", .timeLimit(.minutes(1)))
struct FrontendMOSAdmissionTests {
    @Test(arguments: ["4.5", "4.5.0", "4.500000e+0", "4.8.3"])
    func legacyCompactModelRefusesWithActualDeclarationSource(version: String) async throws {
        let text = "Admission\n.model n nmos level=54 version=\(version)\nM1 d g 0 0 n l=1u w=4u\n.end\n"
        let source = try await SPICEParser().parse(document: .init(text: text, resolvedPath: "legacy.cir", captureID: "legacy-source"),
            configuration: .default, fileResolver: NullFileResolver()).get()
        for profile in MOSInputProfile.allCases {
            do { _ = try lower(source, profile: profile); Issue.record("Legacy native compact model published a circuit") }
            catch let error as MOSResolutionFailure {
                guard case .osdiBindingRequired(let level, let original, let location) = error else {
                    Issue.record("Expected explicit OSDI migration refusal, received \(error)"); continue
                }
                #expect(level == 54 && original == version)
                #expect(location.path == "legacy.cir" && location.line == 2)
                #expect(location.captureID == "legacy-source")
            }
        }
    }

    @Test(arguments: [1, 2, 3])
    func classicalLevelsPreserveExactReleaseAndGeometry(level: Int) async throws {
        let result = try lower(await parsed(".model n nmos level=\(level) vto=.7"))
        guard case .resolved(let mos) = result.circuit.instances[0].mos else { Issue.record("Missing classical MOS"); return }
        #expect(mos.release.level == level && mos.releaseOrigin == .explicitLevel(level))
        #expect(mos.normalizedGeometry.length == 1e-6 && mos.normalizedGeometry.width == 4e-6)
    }

    @Test func activeNonScalarModelInputFailsWithSourceDiagnostic() async throws {
        for name in ["vto", "unrecognized", "kp"] {
            let source = try await parsed(".model n nmos level=1 \(name)=\"bad\"")
            let limits = try FrontendTestLowering.limits()
            let compiled = try NetlistLowering.compile(source, limits: limits)
            var session = try NetlistLowering.beginEvaluation(compiled, profile: .pinnedNgspiceNormalV1, limits: limits, seed: 42)
            do { try session.lower(); Issue.record("Non-scalar coefficient produced a circuit") }
            catch let error as MOSResolutionFailure {
                #expect(error == .schema(.invalidValue(name: name)))
                #expect(session.failureDiagnostic?.instance == "m1")
                #expect(session.failureDiagnostic?.candidateRange != nil)
            }
            #expect(session.circuit == nil)
        }
    }

    @Test func unusedAndDiscardedInvalidCardsDoNotReplaceFirstSourceCard() async throws {
        let source = try await parsed("""
        .model unused nmos level=1 vto="bad"
        .model n nmos level=1 vto=.4
        .model n nmos level=1 vto="bad"
        """)
        let result = try lower(source)
        guard case .resolved(let mos) = result.circuit.instances[0].mos else { Issue.record("Missing MOS"); return }
        #expect(mos.declaration == MOSDeclarationID(1) && mos.release == .level1)
        #expect(result.snapshot.declarations.count == 3)
    }

    @Test func vectorModelCoefficientCannotBecomeOmittedInput() async throws {
        let source = try await parsed(".model n nmos level=1")
        let vector = ParsedModel(name: "n", type: .nmos, level: 1, parameters: ["vto": .numericVector([1, 2])])
        let invalid = ParsedNetlist(components: source.components, models: [vector])
        #expect(throws: MOSResolutionFailure.schema(.invalidValue(name: "vto"))) { _ = try lower(invalid) }
    }

    @Test func invalidWidthFlagsNeverPublishACircuit() async throws {
        for value in ["2", "-1", "\"bad\""] {
            let source = try await parsed(".model n nmos level=1", controls: ".options wnflag=\(value)")
            #expect(throws: (any Error).self) { _ = try lower(source) }
        }
    }

    private func parsed(_ declarations: String, controls: String = "") async throws -> ParsedNetlist {
        try await SPICEParser().parse(source: "Admission\n\(controls)\n\(declarations)\nM1 d g 0 0 n l=1u w=4u\n.end\n").get()
    }

    private func lower(_ source: ParsedNetlist, profile: MOSInputProfile = .pinnedNgspiceNormalV1) throws -> LoweredCircuit {
        let limits = try FrontendTestLowering.limits()
        let compiled = try NetlistLowering.compile(source, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: profile, limits: limits, seed: 42)
        try session.lower()
        return try session.finish()
    }
}

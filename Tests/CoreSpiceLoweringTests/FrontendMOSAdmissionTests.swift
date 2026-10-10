import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import CoreSpiceParsedIR
import CoreSpiceParserSPICE
import Testing

@Suite("MOS source admission", .timeLimit(.minutes(1)))
struct FrontendMOSAdmissionTests {
    private func parsed(_ declarations: String, controls: String = "", model: String = "n") async throws -> ParsedNetlist {
        try await SPICEParser().parse(source: "Admission\n\(controls)\n\(declarations)\nM1 d g 0 0 \(model) l=1u w=4u nf=4\n.end\n").get()
    }

    private func lower(_ parsed: ParsedNetlist, profile: MOSInputProfile = .pinnedNgspiceNormalV1) throws -> LoweredCircuit {
        let limits = try FrontendTestLowering.limits()
        let compiled = try NetlistLowering.compile(parsed, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: profile, limits: limits, seed: 42)
        try session.lower()
        return try session.finish()
    }

    private var bins: String {
        """
        .model n.1 nmos level=54 version=4.8.3 lmin=.1u lmax=2u wmin=.1u wmax=1.5u
        .model n.2 nmos level=54 version=4.8.3 lmin=.1u lmax=2u wmin=2u wmax=5u
        """
    }

    @Test func activeNonScalarModelInputFailsWithSourceDiagnostic() async throws {
        for name in ["vth0", "unrecognized", "lmin"] {
            let source = try await parsed(".model n nmos level=54 version=4.8.3 \(name)=\"bad\"")
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
        .model unused nmos level=54 version=4.8.3 vth0="bad"
        .model n nmos level=54 version=4.8.3 vth0=.4
        .model n nmos level=54 version=4.8.3 vth0="bad"
        """)
        let result = try lower(source)
        guard case .resolved(let mos) = result.circuit.instances[0].mos else { Issue.record("Missing MOS"); return }
        #expect(mos.declaration == MOSDeclarationID(1))
        #expect(result.snapshot.declarations.count == 3)
    }

    @Test func sourceWidthFlagChangesOnlySelectionWidth() async throws {
        for flag in [0, 1] {
            let source = try await parsed(bins, controls: ".options wnflag=\(flag)")
            let result = try lower(source)
            guard case .resolved(let mos) = result.circuit.instances[0].mos else { Issue.record("Missing MOS"); return }
            #expect(mos.symbolNames[Int(mos.selectedName.rawValue)] == (flag == 1 ? "n.1" : "n.2"))
            #expect(mos.normalizedGeometry.width == 4e-6)
            #expect(mos.selectionGeometry.width == (flag == 1 ? 1e-6 : 4e-6))
            #expect(mos.rules.contains(.widthPerFinger) == (flag == 1))
        }
    }

    @Test func invalidOrStrictWidthFlagsNeverPublishACircuit() async throws {
        for value in ["2", "-1", "\"bad\""] {
            let source = try await parsed(bins, controls: ".options wnflag=\(value)")
            #expect(throws: (any Error).self) { _ = try lower(source) }
        }
        let strict = try await parsed(bins, controls: ".options wnflag=1")
        #expect(throws: (any Error).self) { _ = try lower(strict, profile: .coreStrictV1) }
    }
    @Test func typedWidthFlagAndSourceOverrideRetainSelectionIdentity() async throws {
        let source = try await parsed(bins, controls: ".options wnflag=0")
        let limits = try FrontendTestLowering.limits()
        let compiled = try NetlistLowering.compile(source, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .pinnedNgspiceNormalV1, limits: limits, seed: 42)
        try session.lower(globalWidthPerFinger: true)
        let result = try session.finish()
        guard case .resolved(let mos) = result.circuit.instances[0].mos else { Issue.record("Missing MOS"); return }
        #expect(mos.symbolNames[Int(mos.selectedName.rawValue)] == "n.1")
        #expect(mos.rules.contains(.widthPerFinger))
        var strict = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 42)
        #expect(throws: (any Error).self) { try strict.lower(globalWidthPerFinger: true) }
        let bad = try await parsed(bins, controls: ".options wnflag=2")
        let badCompiled = try NetlistLowering.compile(bad, limits: limits)
        var overriding = try NetlistLowering.beginEvaluation(badCompiled, profile: .pinnedNgspiceNormalV1, limits: limits, seed: 42)
        #expect(throws: MOSResolutionFailure.schema(.invalidValue(name: "wnflag"))) {
            try overriding.lower(globalWidthPerFinger: false)
        }
    }

    @Test func vectorModelCoefficientCannotBecomeOmittedInput() async throws {
        let source = try await parsed(".model n nmos level=54 version=4.8.3")
        let vector = ParsedModel(name: "n", type: .nmos, level: 54,
            parameters: ["version": .string("4.8.3"), "vth0": .numericVector([1, 2])])
        let invalid = ParsedNetlist(components: source.components, models: [vector])
        #expect(throws: MOSResolutionFailure.schema(.invalidValue(name: "vth0"))) { _ = try lower(invalid) }
    }

    @Test func unsupportedVersionValueCannotDefaultToAnotherRelease() async throws {
        let source = try await parsed(".model n nmos level=54 version=4.8.3")
        let model = ParsedModel(name: "n", type: .nmos, level: 54, parameters: ["version": .numeric(4.5)])
        let invalid = ParsedNetlist(components: source.components, models: [model])
        #expect(throws: MOSResolutionFailure.schema(.invalidValue(name: "version"))) { _ = try lower(invalid) }
    }

    @Test func localWidthFlagCannotBeSilentlyIgnored() async throws {
        let source = try await SPICEParser().parse(source: """
        Invalid local width control
        .subckt cell d g
        .options wnflag=1
        M1 d g 0 0 n l=1u w=4u nf=4
        .ends
        .model n nmos level=54 version=4.8.3
        X1 d g cell
        .end
        """).get()
        #expect(throws: LoweringError.self) { _ = try lower(source) }
    }

    @Test func sourceWidthFlagsUseLastOccurrenceWithoutRedrawing() async throws {
        let source = try await parsed(bins, controls: ".options WNFLAG={rand()<1} wnflag={rand()<0}")
        let result = try lower(source)
        guard case .resolved(let mos) = result.circuit.instances[0].mos else { Issue.record("Missing MOS"); return }
        #expect(mos.symbolNames[Int(mos.selectedName.rawValue)] == "n.2")
        #expect(result.evaluationProvenance.randomDraws == 2)
    }

}

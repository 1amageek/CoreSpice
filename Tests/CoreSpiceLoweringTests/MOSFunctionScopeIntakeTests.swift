import Testing
import CoreSpiceMOSContracts
import CoreSpiceParserSPICE
import CoreSpiceParsedIR
import CoreSpiceIR
@testable import CoreSpiceLowering

@Suite("MOS declaration function scope consumption", .timeLimit(.minutes(1)))
struct MOSFunctionScopeIntakeTests {
    private func resistance(_ instance: Instance) -> Double? {
        guard case .real(let value) = instance.parameters["r"] else { return nil }
        return value
    }

    @Test func localFunctionsShadowGlobalInDefaultsAndBodyWithoutLeakingToSiblings() async throws {
        let parsed = try await SPICEParser().parse(source: """
        function scope consumption
        .func resistance(x) {x+100}
        .subckt local a b value={resistance(1)}
        .func resistance(x) {x+200}
        .param body={resistance(2)}
        Rdefault a b {value}
        Rbody a b {body}
        .ends
        .subckt sibling a b value={resistance(1)}
        Rdefault a b {value}
        .ends
        Xlocal a 0 local
        Xsibling b 0 sibling
        Rglobal c 0 {resistance(3)}
        .end
        """).get()
        let circuit = try FrontendTestLowering(configuration: .init(maxExpansionDepth: 2)).lower(parsed)
        let values = Dictionary(uniqueKeysWithValues: circuit.instances.map { ($0.name, resistance($0)) })
        #expect(values["xlocal.rdefault"] == 201)
        #expect(values["xlocal.rbody"] == 202)
        #expect(values["xsibling.rdefault"] == 101)
        #expect(values["rglobal"] == 103)
        let restored = try await SPICEParser().parse(source: SPICESerializer().serialize(parsed)).get()
        let roundTrip = try FrontendTestLowering(configuration: .init(maxExpansionDepth: 2)).lower(restored)
        #expect(Dictionary(uniqueKeysWithValues: roundTrip.instances.map { ($0.name, resistance($0)) }) == values)
    }

    @Test func functionFailureRestoresCallerBindingsAndSupportsFollowingExpansion() async throws {
        let parsed = try await SPICEParser().parse(source: """
        failed function scope
        .func resistance(x) {x+100}
        .subckt broken a b value={resistance(1)}
        .func resistance(x) {missing+x}
        .param leaked=9
        Rinside a b {value}
        .ends
        Xbad a 0 broken
        Rafter a 0 {resistance(3)}
        .end
        """).get()
        let limits = try FrontendTestLowering.limits(maxDepth: 2)
        let compiled = try NetlistLowering.compile(parsed, limits: limits)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: .pinnedNgspiceNormalV1, limits: limits, seed: 7)
        do { try session.lower(); Issue.record("Missing local binding must fail") }
        catch is MOSResolutionFailure { }
        #expect(session.failureDiagnostic != nil)
        do { try session.lower(); Issue.record("Failed session must remain terminal") }
        catch is MOSResolutionFailure { }
        let following = ParsedNetlist(components: [parsed.components[1]], controls: parsed.controls,
            functionDefinitions: parsed.functionDefinitions)
        let circuit = try FrontendTestLowering().lower(following)
        #expect(circuit.instances.map(\.name) == ["rafter"])
        #expect(resistance(circuit.instances[0]) == 103)
    }

    @Test func rejectedScopeAdmissionLeavesAllCallerScopesIntact() throws {
        let context = LoweringContext(maxDepth: 1)
        try context.withScope(parameters: ["caller": 7]) {
            try context.registerScopedFunction(name: "owned", parameters: [], body: .literal(11))
            #expect(throws: LoweringError.self) { try context.enterScope() }
            #expect(context.depth == 1)
            #expect(context.parameter("caller") == 7)
            #expect(context.function("owned")?.body == .literal(11))
        }
        #expect(context.depth == 0)
        #expect(context.parameter("caller") == nil)
        #expect(context.function("owned") == nil)
        #expect(throws: LoweringError.self) {
            try context.registerScopedFunction(name: "unowned", parameters: [], body: .literal(1))
        }
    }
}

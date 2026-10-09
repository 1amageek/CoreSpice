import CoreSpiceIR
import CoreSpiceParsedIR
import CoreSpiceParserSPICE
import CoreSpiceLowering
import Testing

@Suite("Charge capacitor selected lowering", .timeLimit(.minutes(1)))
struct ChargeCapacitorLoweringTests {
    @Test func selectedChargeFailsBeforeEvaluationWhileUnusedBodyIsRetained() async throws {
        let source = """
        selected charge closure
        V1 out 0 1
        R1 out 0 1k
        .subckt varactor a
        .param unused=missing
        Cq a 0 q={unresolved*v(a)}
        .ends
        .end
        """
        let parsed = try await SPICEParser().parse(source: source).get()
        let ir = try NetlistLowering().lower(parsed)
        #expect(Set(ir.instances.map(\.name)) == Set(["v1", "r1"]))
        let selected = try await SPICEParser().parse(source: (source + "\n").replacingOccurrences(of: ".end\n", with: "X1 out varactor\n.end\n")).get()
        // Avoid the unrelated local-parameter failure to observe the charge admission owner.
        let charge = try await SPICEParser().parse(source: "charge\nCq out 0 q={unresolved*v(out)}\n.end\n").get()
        for configuration in [NetlistLowering.Configuration.default,
                              .init(expandModels: false, evaluateExpressions: false)] {
            do { _ = try NetlistLowering(configuration: configuration).lower(charge); Issue.record("Charge was executed as capacitance") }
            catch let error as LoweringError {
                guard case .invalidComponent(_, let reason) = error else { throw error }
                #expect(reason == "Charge-based capacitor execution is not implemented")
            }
        }
        #expect(throws: LoweringError.self) { _ = try NetlistLowering().lower(selected) }
    }

    @Test func manuallyParsedMixedRolesCannotBypassChargeAdmission() throws {
        for extra in [[:], ["c": ParsedParameterValue.numeric(1e-9)]] {
            var parameters = extra
            parameters["q"] = .expression(.identifier("unresolved"))
            let component = ParsedComponent(name: "cq", type: .capacitor, nodes: ["out", "0"],
                modelName: "missing_model", passiveModelCandidate: "missing_candidate", parameters: parameters)
            do { _ = try NetlistLowering().lower(ParsedNetlist(components: [component])); Issue.record("Mixed charge roles bypassed admission") }
            catch let error as LoweringError {
                guard case .invalidComponent(_, let reason) = error else { throw error }
                #expect(reason == "Charge-based capacitor execution is not implemented")
            }
        }
    }
}

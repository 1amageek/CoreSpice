import CoreSpiceParsedIR
import CoreSpiceParser
@testable import CoreSpiceParserSPICE
import Testing

@Suite("Charge capacitor source roles")
struct ChargeCapacitorParserTests {
    private let law = "cmin*vm*(v(c0)-v(p2))+((0.5*(cmax+cmin)-cmin)*(v(c0)-v(p2))+0.5*(cmax-cmin)*(1/1.9)*(cnwvc_slope1*log(cosh((v(c0)-v(p2)-cnwvc_vt1)/cnwvc_slope1))+0.9*cnwvc_slope2*log(cosh((v(c0)-v(p2)-cnwvc_vt2)/cnwvc_slope2))))*vm"

    @Test func fullSky130ChargeLawPreservesExactlyOneASTInEverySupportedForm() async throws {
        let expected = try SPICEExpressionParser().parse(law)
        for value in ["'\(law)'", "{\(law)}", law] {
            let parsed = try await SPICEParser().parse(source: "charge law\ncg c0 p2 q=\(value)\n.end\n").get()
            let component = try #require(parsed.components.first)
            #expect(component.type == .capacitor)
            #expect(component.nodes.map(\.name) == ["c0", "p2"])
            #expect(component.parameters == ["q": .expression(expected)])
            #expect(component.modelName == nil)
            #expect(component.passiveModelCandidate == nil)
        }
    }

    @Test func chargeSourceRetainsScopedNamesAndContinuationAST() async throws {
        let expression = "q0*(v(a)-v(b))+max(v(a),v(b))*scale"
        let expected = try SPICEExpressionParser().parse(expression)
        let parsed = try await SPICEParser().parse(source: """
        scoped charge source
        .param q0=1p
        .subckt cell a b params: scale=2
        .param q0=3p
        cq a b q=q0*(v(a)-v(b))+
        + max(v(a),v(b))*scale
        .ends
        .end
        """, fileName: "charge.cir").get()
        let component = try #require(parsed.subcircuits.first?.body.components.first)
        #expect(component.parameters == ["q": .expression(expected)])
        #expect(component.location?.file == "charge.cir")
        #expect(component.location?.line == 5)
        #expect(component.modelName == nil)
        #expect(component.passiveModelCandidate == nil)
    }

    @Test func quotedAndBracedNumericChargeRemainExpressionsAndRoundTrip() async throws {
        for value in ["'2p'", "{2p}", "q0*(v(a)-v(b))", "{q0}"] {
            let parsed = try await SPICEParser().parse(source: "charge round trip\ncq a b q=\(value)\n.end\n").get()
            let component = try #require(parsed.components.first)
            let charge = try #require(component.parameters["q"])
            guard case .expression = charge else {
                Issue.record("Charge source must preserve its expression role")
                continue
            }
            let serialized = SPICESerializer().serialize(parsed)
            #expect(serialized.contains("cq a b q={"))
            let again = try await SPICEParser().parse(source: serialized).get()
            #expect(again.components.first?.parameters == component.parameters)
            #expect(again.components.first?.modelName == nil)
            #expect(again.components.first?.passiveModelCandidate == nil)
        }
    }

    @Test func mixedChargeRolesAreExplicitlyUnsupportedInEveryOrdering() async {
        for tail in ["q={v(a)} c=1p", "c=1p q={v(a)}", "q={v(a)} 1p", "1p q={v(a)}",
                     "cm q={v(a)}", "1p cm q={v(a)}", "q={v(a)} cm", "q={v(a)} m=2",
                     "m=2 q={v(a)}", "q={v(a)} tc1=.01", "tc1=.01 q={v(a)}"] {
            let result = await SPICEParser().parse(source: "mixed charge\ncq a 0 \(tail)\n.model cm C cap=2p\n.end\n",
                fileName: "mixed-charge.cir")
            #expect(!result.isSuccess)
            #expect(result.diagnostics.contains {
                $0.severity == .error && $0.message.contains("not implemented") && $0.location?.line == 2
            })
        }
    }

    @Test func missingNumericDuplicateAndTrailingChargeValuesFail() async {
        for card in ["cq a q={v(a)}", "cq a 0 q=", "cq a 0 q=2p", "cq a 0 q=-2p", "cq a 0 q=+2p",
                     "cq a 0 q={v(a)} q={v(a)}", "cq a 0 q=q0 stray", "cq a 0 q={v(a)} stray",
                     "cq a 0 q=q0*", "cq a 0 q={}"] {
            let result = await SPICEParser().parse(source: "invalid charge\n\(card)\n.end\n", fileName: "invalid-charge.cir")
            #expect(!result.isSuccess)
            #expect(result.diagnostics.contains { $0.severity == .error && $0.location?.file == "invalid-charge.cir" })
        }
    }

    @Test func malformedChargeContinuationReportsOriginalPhysicalLocation() async {
        let result = await SPICEParser().parse(source: "bad charge\ncq a 0 q=q0*\n+ (v(a)-)\n.end\n", fileName: "continuation-charge.cir")
        #expect(!result.isSuccess)
        #expect(result.diagnostics.contains { $0.severity == .error && $0.location?.line == 3 })
    }
}

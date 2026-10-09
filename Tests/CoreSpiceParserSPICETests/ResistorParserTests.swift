import Testing
import CoreSpiceParser
import CoreSpiceParsedIR
@testable import CoreSpiceParserSPICE

@Suite("Resistor source roles")
struct ResistorParserTests {
    @Test func unquotedNamedResistanceConsumesIsoWellExpressionAndStopsAtAssignment() async throws {
        let expression = "rspwres*((l+dl)/w)*(1-av*(max(v(r0),v(r1))-min(v(r0),v(r1))))*(1+bv*(v(b)-min(v(r0),v(r1))))*(1+local_vt*(temper-tref)+ut*(temper-tref)*(temper-tref))"
        let expected = try SPICEExpressionParser().parse(expression)
        for name in ["r", "resistance"] {
            let parsed = try await SPICEParser().parse(source: """
            isowell runtime grammar
            R0 r0 r1 \(name)=rspwres*((l+dl)/w)*(1-av*(max(v(r0),v(r1))-min(v(r0),v(r1))))*
            + (1+bv*(v(b)-min(v(r0),v(r1))))*(1+local_vt*(temper-tref)+ut*(temper-tref)*(temper-tref)) tc1=.01 tc2=.0001 m=2 noisy=0
            .end
            """, fileName: "isowell.cir").get()
            let component = try #require(parsed.components.first)
            #expect(component.parameters[name] == .expression(expected))
            #expect(component.parameters["tc1"] == .numeric(0.01))
            #expect(component.parameters["tc2"] == .numeric(0.0001))
            #expect(component.parameters["m"] == .numeric(2))
            #expect(component.parameters["noisy"] == .numeric(0))
            #expect(component.modelName == nil)
            #expect(component.passiveModelCandidate == nil)
        }
    }

    @Test func namedResistancePreservesQuotedBracedAndStaticRoles() async throws {
        let parsed = try await SPICEParser().parse(source: """
        named resistor roles
        R1 a 0 r=100 m=2
        R2 a 0 r='rv*2' noisy=0
        R3 a 0 resistance={rv*2} tc1=.01
        R4 a 0 head r=rv*2 m=3
        R5 a 0 r=-100 m=2
        R6 a 0 r=+100 m=2
        .model head R r=400
        .end
        """).get()
        let expected = ParsedParameterValue.expression(.binaryOperation(.multiply, .identifier("rv"), .literal(2)))
        #expect(parsed.components[0].parameters["r"] == .numeric(100))
        #expect(parsed.components[1].parameters["r"] == expected)
        #expect(parsed.components[2].parameters["resistance"] == expected)
        #expect(parsed.components[3].parameters["r"] == expected)
        #expect(parsed.components[3].modelName == "head")
        #expect(parsed.components[4].parameters["r"] == .numeric(-100))
        #expect(parsed.components[5].parameters["r"] == .numeric(100))
    }

    @Test func malformedUnquotedResistanceReportsOriginalContinuationLocation() async {
        for card in ["R1 a 0 r=rv stray m=2", "R1 a 0 r=rv*\n+ (temper-)"] {
            let result = await SPICEParser().parse(source: "bad resistance\n\(card)\n.end\n", fileName: "bad.cir")
            #expect(!result.isSuccess)
            #expect(result.diagnostics.contains {
                $0.severity == .error && $0.location?.file == "bad.cir" && ($0.location?.line ?? 0) >= 2
            })
            if card.contains("\n") {
                #expect(result.diagnostics.contains { $0.location?.line == 3 })
            }
        }
    }

    @Test func modelAndNamedResistanceRemainSeparateAcrossForwardScope() async throws {
        let parsed = try await SPICEParser().parse(source: """
        resistor source roles
        .param rv=123
        R1 a 0 head r=100 tc1=.01
        R2 a 0 rv
        R3 a 0 99 head
        R6 a 0 head 101
        .model head R tnom=25 unused_coefficient=17
        .subckt cell a
        R4 a 0 local r=200
        R5 a 0 head
        .model local R r=300
        .ends
        .end
        """).get()
        #expect(parsed.models[0].type.rawValue == "R")
        #expect(parsed.models[0].parameters["unused_coefficient"] == .numeric(17))
        #expect(parsed.components[0].modelName == "head")
        #expect(parsed.components[0].parameters["r"] == .numeric(100))
        #expect(parsed.components[1].modelName == nil)
        #expect(parsed.components[1].parameters["r"] == .expression(.identifier("rv")))
        #expect(parsed.components[2].modelName == "head")
        #expect(parsed.components[2].parameters["r"] == .numeric(99))
        #expect(parsed.components[3].modelName == "head")
        #expect(parsed.components[3].parameters["r"] == .numeric(101))
        #expect(parsed.subcircuits[0].body.components[0].modelName == "local")
        #expect(parsed.subcircuits[0].body.components[1].modelName == "head")
        let serialized = SPICESerializer().serialize(parsed)
        let again = try await SPICEParser().parse(source: serialized).get()
        #expect(again.components[0].modelName == "head")
        #expect(again.components[0].parameters == parsed.components[0].parameters)
    }

    @Test func malformedResistanceIsNotDiscarded() async {
        for card in ["R1 a", "R1 a 0", "R1 a 0 100 200", "R1 a 0 foo bar baz", "R1 a 0 r="] {
            let result = await SPICEParser().parse(source: "bad resistor\n\(card)\n.end\n")
            #expect(!result.isSuccess)
            #expect(result.diagnostics.contains { $0.severity == .error && $0.location != nil })
        }
    }
}

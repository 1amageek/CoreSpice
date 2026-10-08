import Testing
import CoreSpiceParser
import CoreSpiceParsedIR
@testable import CoreSpiceParserSPICE

@Suite("Resistor source roles")
struct ResistorParserTests {
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

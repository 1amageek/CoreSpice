import Testing
import CoreSpiceParser
import CoreSpiceParsedIR
@testable import CoreSpiceParserSPICE

@Suite("Capacitor source roles")
struct CapacitorParserTests {
    @Test func declarationsPreserveSourceValuesAndBareSymbolsRemainUnresolved() async throws {
        let parsed = try await SPICEParser().parse(source: """
        capacitor source roles
        .param cv=5n
        C1 a 0 cm
        C2 a 0 cv
        C3 a 0 unknown
        C4 a 0 wrong
        C5 a 0 c
        .model cm C cox=1 capsw=2 w=3 tnom=25 tc1=.01 tc2=.001
        .model cv C cap=8n
        .model wrong R r=100
        .model c C cap=9n
        .end
        """, fileName: "capacitor.cir").get()
        let model = try #require(parsed.models.first)
        #expect(model.type == .capacitor)
        #expect(model.parameters == ["cox": .numeric(1), "capsw": .numeric(2), "w": .numeric(3),
            "tnom": .numeric(25), "tc1": .numeric(0.01), "tc2": .numeric(0.001)])
        #expect(model.location?.file == "capacitor.cir")
        for (component, symbol) in zip(parsed.components, ["cm", "cv", "unknown", "wrong", "c"]) {
            #expect(component.modelName == nil)
            #expect(component.passiveModelCandidate == symbol)
            #expect(component.parameters == ["c": .expression(.identifier(symbol))])
        }
    }

    @Test func leadingAndPostModelValuesPreserveDistinctRolesAndLastValueWins() async throws {
        let parsed = try await SPICEParser().parse(source: """
        explicit capacitor roles
        C1 a 0 cm 2n
        C2 a 0 cm c=2n m=2
        C3 a 0 cm {cv}
        C4 a 0 2n cm
        C5 a 0 {cv} cm
        C6 a 0 2n cm 4n
        C7 a 0 2n missing
        C8 a 0 2n wrong
        .model cm C cap=3n
        .model wrong R r=100
        .end
        """).get()
        for component in parsed.components {
            #expect(component.passiveModelCandidate == nil)
        }
        #expect(parsed.components.map(\.modelName) == ["cm", "cm", "cm", "cm", "cm", "cm", "missing", "wrong"])
        #expect(parsed.components[0].parameters == ["c": .numeric(2e-9)])
        #expect(parsed.components[1].parameters == ["c": .numeric(2e-9), "m": .numeric(2)])
        #expect(parsed.components[2].parameters == ["c": .expression(.identifier("cv"))])
        #expect(parsed.components[3].parameters == ["c": .numeric(2e-9)])
        #expect(parsed.components[4].parameters == ["c": .expression(.identifier("cv"))])
        #expect(parsed.components[5].parameters == ["c": .numeric(4e-9)])
        #expect(parsed.models[0].parameters == ["cap": .numeric(3 * 1e-9)])
    }

    @Test func explicitValueSyntaxNeverAcquiresCandidate() async throws {
        let parsed = try await SPICEParser().parse(source: """
        explicit ideal capacitors
        C1 a 0 2n
        C2 a 0 {cv}
        C3 a 0 'cv'
        C4 a 0 c=cv m=2
        C5 a 0 -2n
        C6 a 0 +2n
        .model cv C cap=3n
        .end
        """).get()
        for component in parsed.components {
            #expect(component.passiveModelCandidate == nil)
            #expect(component.modelName == nil)
        }
        for index in 1...3 {
            #expect(parsed.components[index].parameters["c"] == .expression(.identifier("cv")))
        }
        #expect(parsed.components[4].parameters["c"] == .numeric(-2e-9))
        #expect(parsed.components[5].parameters["c"] == .numeric(2e-9))
    }

    @Test func namedCapacitanceConsumesCompleteExpressionAndStopsAtAssignment() async throws {
        let expression = "cv*(1+tc*(temper-tref))+max(v(a),v(b))*scale"
        let expected = try SPICEExpressionParser().parse(expression)
        let parsed = try await SPICEParser().parse(source: """
        capacitor runtime expression
        C1 a b cm c=cv*(1+tc*(temper-tref))+
        + max(v(a),v(b))*scale m=2 tc1=.01
        .model cm C cap=3n
        .end
        """).get()
        let component = try #require(parsed.components.first)
        #expect(component.modelName == "cm")
        #expect(component.passiveModelCandidate == nil)
        #expect(component.parameters == ["c": .expression(expected), "m": .numeric(2), "tc1": .numeric(0.01)])
    }

    @Test func forwardAndSubcircuitCandidatesSurviveSerialization() async throws {
        let parsed = try await SPICEParser().parse(source: """
        capacitor round trip
        C1 a 0 cm
        C2 a 0 cm c=2n
        C3 a 0 2n cm 4n
        .model cm C cap=3n
        .subckt cell a params: cv=5n
        C4 a 0 cv
        .model cv C cap=6n
        .ends
        .end
        """).get()
        #expect(parsed.subcircuits[0].body.components[0].passiveModelCandidate == "cv")
        let serialized = SPICESerializer().serialize(parsed)
        #expect(serialized.contains("c1 a 0 cm"))
        #expect(!serialized.contains("c1 a 0 cm c="))
        let again = try await SPICEParser().parse(source: serialized).get()
        for (first, second) in zip(parsed.components, again.components) {
            #expect(first.modelName == second.modelName)
            #expect(first.passiveModelCandidate == second.passiveModelCandidate)
            #expect(first.parameters == second.parameters)
        }
        #expect(again.subcircuits[0].body.components[0].passiveModelCandidate == "cv")
        #expect(parsed.components[0].description == "c1 a 0 cm")
    }

    @Test func serializerOmitsOnlyTheCorrespondingProvisionalExpression() {
        let component = ParsedComponent(name: "C1", type: .capacitor,
            nodes: [ParsedNodeRef(name: "a"), ParsedNodeRef(name: "0")],
            passiveModelCandidate: "cm", parameters: ["c": .numeric(2e-9), "r": .numeric(100)])
        #expect(component.description.contains("c="))
        #expect(component.description.contains("r="))
        let serialized = SPICESerializer().serialize(ParsedNetlist(components: [component]))
        #expect(serialized.contains("c="))
        #expect(serialized.contains("r="))
    }

    @Test func malformedCapacitanceNeverDiscardsTrailingTokens() async {
        for card in ["C1 a", "C1 a 0", "C1 a 0 2n 3n", "C1 a 0 cm 2n 3n",
                     "C1 a 0 2n cm 3n 4n", "C1 a 0 cm stray", "C1 a 0 c=2n cm",
                     "C1 a 0 c=cv stray m=2", "C1 a 0 c=", "C1 a 0 {cv} {cv}",
                     "C1 a 0 cm {cv} stray", "C1 a 0 c=cv*\n+ (temper-)"] {
            let result = await SPICEParser().parse(source: "bad capacitance\n\(card)\n.end\n", fileName: "bad-c.cir")
            #expect(!result.isSuccess)
            #expect(result.diagnostics.contains { $0.severity == .error && $0.location?.file == "bad-c.cir" })
            if card.contains("\n") {
                #expect(result.diagnostics.contains { $0.location?.line == 3 })
            }
        }
    }
}

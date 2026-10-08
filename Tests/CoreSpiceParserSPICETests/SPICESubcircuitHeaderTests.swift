import Testing
import CoreSpiceParserSPICE
import CoreSpiceParser
import CoreSpiceParsedIR

@Suite("SPICE subcircuit header defaults", .timeLimit(.minutes(1)))
struct SPICESubcircuitHeaderTests {
    @Test(arguments: ["", "PARAMS", "PARAMS:"])
    func optionalMarkersRetainNumericPortsAndAllDefaultValues(marker: String) async throws {
        let source = """
        Subcircuit header values
        .param baseline=2000
        .subckt cell input 1 2 \(marker) r=1000 delta=-2 inherited=baseline doubled={r*2}
        R1 input 1 {r}
        .ends cell
        V1 source 0 1
        .end
        """
        let result = await SPICEParser().parse(source: source)
        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.subcircuits.count == 1)
        let cell = try #require(netlist.subcircuits.first)
        #expect(cell.name == "cell")
        #expect(cell.ports == ["input", "1", "2"])
        let expected: [String: ParsedParameterValue] = [
            "r": .numeric(1000),
            "delta": .numeric(-2),
            "inherited": .expression(.identifier("baseline")),
            "doubled": .expression(.binaryOperation(.multiply, .identifier("r"), .literal(2))),
        ]
        #expect(cell.parameters == expected)
        #expect(cell.body.components.map(\.name) == ["r1"])
        #expect(cell.body.components.first?.nodes.map(\.name) == ["input", "1"])
        #expect(cell.body.parameters.isEmpty)
        #expect(netlist.components.map(\.name) == ["v1"])
        #expect(netlist.parameters == ["baseline": .literal(2000)])
    }

    @Test(arguments: ["\n", "\r\n"])
    func continuedHeaderDefaultsControlOnlyTheirLocalConditionalScope(lineEnding: String) async throws {
        let source = [
            "Local conditional header defaults",
            ".param enabled=0 outer=7",
            ".subckt gate input output",
            "* Header defaults continue after this comment",
            "",
            "  + enabled=1 resistance=1000",
            ".if enabled",
            ".param body_local=3",
            "Rselected input output {resistance}",
            ".else",
            "Rwrong input output 9000",
            ".endif",
            ".ends gate",
            ".subckt sibling input output enabled=0",
            ".if enabled",
            "Rleaked input output 9000",
            ".else",
            "Rsibling input output 2000",
            ".endif",
            ".ends sibling",
            ".if enabled",
            "Rparent_leaked parent 0 9000",
            ".else",
            "Rparent parent 0 7000",
            ".endif",
            ".end",
            "",
        ].joined(separator: lineEnding)
        let result = await SPICEParser().parse(source: source)
        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.subcircuits.map(\.name) == ["gate", "sibling"])
        let gate = try #require(netlist.subcircuits.first { $0.name == "gate" })
        let sibling = try #require(netlist.subcircuits.first { $0.name == "sibling" })
        #expect(gate.ports == ["input", "output"])
        #expect(gate.parameters == ["enabled": .numeric(1), "resistance": .numeric(1000)])
        #expect(gate.body.components.map(\.name) == ["rselected"])
        #expect(gate.body.parameters == ["body_local": .literal(3)])
        #expect(sibling.parameters == ["enabled": .numeric(0)])
        #expect(sibling.body.components.map(\.name) == ["rsibling"])
        #expect(sibling.body.parameters.isEmpty)
        #expect(netlist.components.map(\.name) == ["rparent"])
        #expect(netlist.parameters == ["enabled": .literal(0), "outer": .literal(7)])
    }

    @Test(arguments: ["r=1000 stray", "r=", "r==1"])
    func malformedDefaultAssignmentsProducePhysicalParserErrors(fields: String) async throws {
        let source = "Header failure\n.subckt cell a b \(fields)\nR1 a b 1000\n.ends cell\n.end\n"
        let fileName = "malformed-subcircuit.spice"
        let result = await SPICEParser().parse(source: source, fileName: fileName)
        #expect(!result.isSuccess)
        let diagnostic = try #require(result.errors.first)
        #expect(diagnostic.location?.file == fileName)
        #expect(diagnostic.location?.line == 2)
        #expect(try #require(diagnostic.location).column >= 18)
        #expect(throws: ParserDiagnostic.self) { _ = try result.get() }
    }
}

import Testing
import CoreSpiceParserSPICE
import CoreSpiceParser
import CoreSpiceParsedIR

@Suite("SPICE comment-interrupted continuation", .timeLimit(.minutes(1)))
struct SPICEContinuationTests {
    @Test(arguments: ["\n", "\r\n"])
    func modelParametersSurviveCommentsAndBlankLines(lineEnding: String) async throws {
        // The ordering and comment boundaries follow an unchanged Sky130 model card.
        let source = [
            "Sky130 model continuation",
            ".model sky130_fd_pr__nfet_01v8__model.0 nmos",
            "* Model Flag Parameters",
            "+ lmin=2.0e-05 lmax=0.0001 wmin=7.0e-06 wmax=0.0001",
            "+ level=54.0 version=4.5",
            "+",
            "",
            "  * Process Parameters",
            "\t*(mismatch parameter retained as a comment)",
            "  + binunit=2.0 capmod=2.0",
            "\t+ toxm=4.148e-9 epsrox=3.9",
            "* Basic Model Parameters",
            "+ vth0=0.5190093",
            "R1 d 0 1000",
            ".end",
            "",
        ].joined(separator: lineEnding)
        let result = await SPICEParser().parse(source: source, fileName: "sky130-continuation.spice")
        #expect(result.isSuccess)
        #expect(result.errors.isEmpty)
        let netlist = try result.get()
        #expect(netlist.title == "sky130 model continuation")
        #expect(netlist.models.count == 1)
        let model = try #require(netlist.models.first)
        #expect(model.name == "sky130_fd_pr__nfet_01v8__model.0")
        #expect(model.type == .nmos)
        #expect(model.level == 54)
        let expected: [String: ParsedParameterValue] = [
            "lmin": .numeric(2.0e-05), "lmax": .numeric(0.0001),
            "wmin": .numeric(7.0e-06), "wmax": .numeric(0.0001),
            "version": .string("4.5"), "binunit": .numeric(2.0),
            "capmod": .numeric(2.0), "toxm": .numeric(4.148e-9),
            "epsrox": .numeric(3.9), "vth0": .numeric(0.5190093),
        ]
        #expect(model.parameters == expected)
        #expect(netlist.components.count == 1)
        let resistor = try #require(netlist.components.first)
        #expect(resistor.name == "r1")
        #expect(resistor.nodes.map(\.name) == ["d", "0"])
        #expect(resistor.parameters == ["r": .numeric(1000)])
    }

    @Test(arguments: ["\n", "\r\n"])
    func ordinaryStatementsAndStandaloneCommentsRemainSeparate(lineEnding: String) async throws {
        let source = [
            "* Standalone title",
            "  * Standalone before model",
            ".model nch nmos level=54 version=4.5",
            "* Model continuation comment",
            "+ vth0=0.7",
            "  * Standalone before resistor",
            "R1 in out 1000",
            "* Resistor continuation comment",
            "",
            "\t+ tc=0.01",
            "* Standalone before capacitor",
            "C1 out 0 1e-12",
            ".param first=1",
            "* Parameter continuation comment",
            "+ second=2",
            ".param third=3",
            ".model pch pmos level=54 version=4.5 vth0=-0.7",
            "* Standalone tail",
            ".end",
            "",
        ].joined(separator: lineEnding)
        let result = await SPICEParser().parse(source: source)
        #expect(result.isSuccess)
        let netlist = try result.get()
        #expect(netlist.title == "Standalone title")
        #expect(netlist.models.map(\.name) == ["nch", "pch"])
        let nmos = try #require(netlist.models.first { $0.name == "nch" })
        let pmos = try #require(netlist.models.first { $0.name == "pch" })
        #expect(nmos.parameters == ["version": .string("4.5"), "vth0": .numeric(0.7)])
        #expect(pmos.parameters == ["version": .string("4.5"), "vth0": .numeric(-0.7)])
        #expect(netlist.components.map(\.name) == ["r1", "c1"])
        let resistor = try #require(netlist.components.first { $0.name == "r1" })
        let capacitor = try #require(netlist.components.first { $0.name == "c1" })
        #expect(resistor.nodes.map(\.name) == ["in", "out"])
        #expect(resistor.parameters == ["r": .numeric(1000), "tc": .numeric(0.01)])
        #expect(capacitor.nodes.map(\.name) == ["out", "0"])
        #expect(capacitor.parameters == ["c": .numeric(1e-12)])
        #expect(netlist.parameters == ["first": .literal(1), "second": .literal(2), "third": .literal(3)])

        var lexer = SPICELexer(source: source)
        let comments = lexer.tokenize().compactMap { token -> String? in
            guard case .comment(let text) = token.token else { return nil }
            return text
        }
        for standalone in ["Standalone title", "Standalone before model", "Standalone before resistor",
                           "Standalone before capacitor", "Standalone tail"] {
            #expect(comments.contains { $0.contains(standalone) })
        }
    }

    @Test(arguments: ["\n", "\r\n"])
    func physicalTokenAndDiagnosticLocationsSurviveContinuation(lineEnding: String) async throws {
        let source = [
            "Continuation diagnostic",
            ".model nch nmos",
            "* Model Flag Parameters",
            "+ level=54 version=4.5",
            "",
            "  * Process Parameters",
            "  + toxm=4.148e-9",
            "Rbad out 0 4.8.3",
            ".end",
            "",
        ].joined(separator: lineEnding)
        let fileName = "physical-location.spice"
        var lexer = SPICELexer(source: source, fileName: fileName)
        let tokens = lexer.tokenize()
        let processParameter = try #require(tokens.first { $0.token == .identifier("toxm") })
        #expect(processParameter.location == SourceLocation(file: fileName, line: 7, column: 5))
        let nextComponent = try #require(tokens.first { $0.token == .identifier("rbad") })
        #expect(nextComponent.location == SourceLocation(file: fileName, line: 8, column: 1))

        let result = await SPICEParser().parse(source: source, fileName: fileName)
        #expect(!result.isSuccess)
        let diagnostic = try #require(result.errors.first {
            $0.message == "Version literal '4.8.3' is not a numerical component value"
        })
        #expect(diagnostic.location == SourceLocation(file: fileName, line: 8, column: 12))
    }
}

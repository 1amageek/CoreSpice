import CoreSpiceParsedIR
import CoreSpiceParser
import CoreSpiceParserSPICE
import Testing

@Suite("Model braced numeric quote elision", .timeLimit(.minutes(1)))
struct BracedQuotedExpressionTests {
    @Test func conditionalProjectionAndCallerConfigurationRemainAuthoritative() async throws {
        let source = """
        Projected model coefficient
        .model rm r rsh={"A"
        .if 0
        + +ignored
        .endif
        + +B}
        .end
        """
        let configuration = ParserConfiguration(caseInsensitive: false)
        let quoted = try await SPICEParser().parse(source: source, configuration: configuration).get()
        let flat = try await SPICEParser().parse(source: source.replacingOccurrences(of: "\"A\"", with: "A"),
            configuration: configuration).get()
        #expect(quoted.models.first?.parameters == flat.models.first?.parameters)
        #expect(quoted.models.first?.parameters["rsh"] == .expression(.binaryOperation(.add,
            .identifier("A"), .identifier("B"))))
    }

    @Test func mixedSingleQuotedSubstringsCannotBecomeNewNumericSuccess() async {
        let result = await SPICEParser().parse(source: "Mixed quotes\n.model rm r rsh={\"1\"+'2'}\n.end\n")
        #expect(!result.isSuccess)
        #expect(result.errors.contains { $0.message.contains("Single-quoted substrings") })
    }

    @Test func originalSky130CoefficientRetainsItsCompleteAST() async throws {
        let text = "Model coefficient\n.model rm r dw={\"-tol_nfom/2-nfom_dw/2\"}\n.end\n"
        let parsed = try await SPICEParser().parse(source: text).get()
        let expected = ParsedExpression.binaryOperation(.subtract,
            .binaryOperation(.divide, .unaryOperation(.negate, .identifier("tol_nfom")), .literal(2)),
            .binaryOperation(.divide, .identifier("nfom_dw"), .literal(2)))
        #expect(parsed.models.first?.parameters["dw"] == .expression(expected))
    }

    @Test func quoteSpacesPreserveFlatPrecedenceAndConditionalScope() async throws {
        let cases = [
            (#"2*"a+b""#, "2*a+b"),
            (#"a"+"b"#, "a+b"),
            (#""q?"a:b"#, "q?a:b"),
            (#"q?"v(x:y)":i(branch:r)"#, "q?v(x:y):i(branch:r)")
        ]
        for (quoted, flat) in cases {
            let text = "Flat model expression\n.model rm r dw={\(quoted)}\n.end\n"
            let parsed = try await SPICEParser().parse(source: text).get()
            let expected = try SPICEExpressionParser().parse(flat)
            #expect(parsed.models.first?.parameters["dw"] == .expression(expected))
            let restored = try await SPICEParser().parse(source: SPICESerializer().serialize(parsed)).get()
            #expect(restored.models.first?.parameters == parsed.models.first?.parameters)
        }
    }

    @Test func consecutiveModelSpansAndConditionalLinesKeepOriginalSourceCoordinates() async throws {
        let text = """
        Active model spans
        .if 0
        .model hidden r dw={"wrong"}
        .endif
        .model first r dw={"a+b"} dl={"c-d"}
        .subckt cell p n
        .model inner r dw={"e/f"}
        .ends cell
        .model last r dw={"g*h"}
        .end
        """
        let parsed = try await SPICEParser().parse(source: text).get()
        #expect(parsed.models.map(\.name) == ["first", "last"])
        #expect(parsed.models[0].parameters["dl"] == .expression(.binaryOperation(.subtract,
            .identifier("c"), .identifier("d"))))
        #expect(parsed.subcircuits.first?.body.models.first?.parameters["dw"] == .expression(
            .binaryOperation(.divide, .identifier("e"), .identifier("f"))))
        #expect(parsed.models[1].parameters["dw"] == .expression(.binaryOperation(.multiply,
            .identifier("g"), .identifier("h"))))
    }

    @Test(arguments: ["\n", "\r\n"])
    func malformedRawInteriorsReportPhysicalColumns(lineEnding: String) async throws {
        for (interior, marker) in [(#"1"k""#, "k"), (#""a+@""#, "@"), (#""a\"+b""#, "\\"),
                                   (#""""#, "}"), (#"2*"""#, "}")] {
            let card = "  + dw={\(interior)}"
            let text = ["Malformed model", ".model rm r rsh=1", "* interruption", "", card, ".end", ""].joined(separator: lineEnding)
            let result = await SPICEParser().parse(source: text, fileName: "model-raw.sp")
            #expect(!result.isSuccess)
            let diagnostic = try #require(result.errors.first)
            let markerIndex = try #require(card.range(of: marker)?.lowerBound)
            #expect(diagnostic.location == SourceLocation(file: "model-raw.sp", line: 5,
                column: card.distance(from: card.startIndex, to: markerIndex) + 1))
        }
    }

    @Test func otherNumericAndTextRolesKeepTheirExistingContracts() async throws {
        for card in [#".param p="2""#, #".param p={"2"}"#,
                     ".subckt cell p n gain={\"2\"}\n.ends cell", #"X1 p 0 cell gain={"2"}"#,
                     #".model rm r level={"54"}"#, #".model rm r version={"4.5"}"#] {
            let result = await SPICEParser().parse(source: "Other numeric role\n\(card)\n.end\n")
            #expect(!result.isSuccess)
        }
        let text = #"""
        Text roles stay opaque
        .model rm r note="a+b" version="4.50.0-Exact" dw={"a+b"}
        .subckt cell p n note="a+b"
        Rinside p n 1k
        .ends cell
        X1 p 0 cell note="a+b"
        .include "Exact/Model's.spice"
        .end
        """#
        let parsed = try await SPICEParser().parse(source: text).get()
        #expect(parsed.models.first?.parameters["note"] == .string("a+b"))
        #expect(parsed.models.first?.parameters["version"] == .string("4.50.0-Exact"))
        #expect(parsed.subcircuits.first?.parameters["note"] == .string("a+b"))
        #expect(parsed.components.first?.parameters["note"] == .string("a+b"))
        let restored = try await SPICEParser().parse(source: SPICESerializer().serialize(parsed)).get()
        #expect(restored.models.first?.parameters == parsed.models.first?.parameters)
        #expect(restored.controls.contains { control in
            if case .include(let path, _) = control { return path == "Exact/Model's.spice" }
            return false
        })
    }
}

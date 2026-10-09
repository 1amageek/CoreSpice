import CoreSpiceParsedIR
import CoreSpiceParser
@testable import CoreSpiceParserSPICE
import Testing

@Suite("Conditional delimiters and reference names")
struct SPICEConditionalDelimiterTests {
    @Test func adjacentAndNestedConditionalsKeepTheirExactAST() throws {
        let parser = SPICEExpressionParser()
        let a = ParsedExpression.identifier("a")
        let b = ParsedExpression.identifier("b")
        let c = ParsedExpression.identifier("c")
        #expect(try parser.parse("1?a:b") == .conditional(condition: .literal(1), then: a, else: b))
        #expect(try parser.parse("1?0?a:b:c") == .conditional(condition: .literal(1),
            then: .conditional(condition: .literal(0), then: a, else: b), else: c))
        #expect(try parser.parse("0?a:1?b:c") == .conditional(condition: .literal(0), then: a,
            else: .conditional(condition: .literal(1), then: b, else: c)))
        #expect(try parser.parse("1?(0?a:b):c") == .conditional(condition: .literal(1),
            then: .conditional(condition: .literal(0), then: a, else: b), else: c))
    }

    @Test func conditionalReferenceNamesAndFollowingCardNamesRemainExact() throws {
        let expression = try SPICEExpressionParser().parse("q?v(x:y):i(vbranch:r)")
        #expect(expression == .conditional(condition: .identifier("q"),
            then: .functionCall(name: "v", arguments: [.identifier("x:y")]),
            else: .functionCall(name: "i", arguments: [.identifier("vbranch:r")])))
        var lexer = SPICELexer(source: ".param q={a?b:c}\nR1 x:y 0 1k\n.subckt cell a b params: r=1k\n")
        let tokens = lexer.tokenize()
        #expect(tokens.contains { $0.token == .identifier("x:y") })
        #expect(tokens.contains { $0.token == .identifier("params:") })
        let colon = try #require(tokens.first { $0.token == .colon })
        #expect(colon.location.line == 1)
        #expect(colon.location.column == 14)
    }

    @Test func modelAndCommentInterruptedContinuationPreserveConditionalMeaning() async throws {
        let source = "conditional model\r\n.model rmodel r p2={q?\r\n* question ? and colon : are comment text\r\n\r\n+ a+b:c}\r\nR1 x:y 0 1k\r\n.end\r\n"
        let parsed = try await SPICEParser().parse(source: source).get()
        #expect(parsed.models.first?.parameters["p2"] == .expression(.conditional(
            condition: .identifier("q"),
            then: .binaryOperation(.add, .identifier("a"), .identifier("b")),
            else: .identifier("c"))))
        #expect(parsed.components.first?.nodes.first?.name == "x:y")
    }

    @Test func malformedConditionalDelimitersRefuseCompleteExpression() {
        for text in ["1?a", "1?:b", "1?a:", "1?a:b:c", "1?(a?b):c"] {
            #expect(throws: ParserDiagnostic.self) { try SPICEExpressionParser().parse(text) }
        }
    }

    @Test func incompletePreviousCardCannotChangeNextCardTokenNames() {
        var lexer = SPICELexer(source: ".param bad={q?a\nR1 x:y 0 1k\n")
        #expect(lexer.tokenize().contains { $0.token == .identifier("x:y") })
    }
}

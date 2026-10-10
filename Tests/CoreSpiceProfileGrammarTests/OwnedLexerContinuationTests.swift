import CoreSpiceParsedIR
@testable import CoreSpiceParserSPICE
import Testing

@Suite("Owned lexer continuation work", .timeLimit(.minutes(1)))
struct OwnedLexerContinuationTests {
    @Test(arguments: ["\n", "\r\n"])
    func manyModelContinuationsMatchOrdinaryTokensWithLinearWork(newline: String) throws {
        let coefficientCount = 1024
        var lines = ["* Original title", ".model nch nmos level=54 version=4.5"]
        for index in 0..<coefficientCount {
            if index.isMultiple(of: 16) { lines.append("* Coefficient group"); lines.append("") }
            lines.append("  + p\(index)=1")
        }
        lines += ["* Standalone tail", "R1 d 0 1000", ".end", ""]
        let source = lines.joined(separator: newline)
        var ordinary = SPICELexer(source: source, fileName: "continued-model.spice")
        var bounded = SPICELexer(source: source, fileName: "continued-model.spice")
        let expected = ordinary.tokenize()
        let resources = GrammarTestResources()
        var owned: SPICEOwnedTokens? = try bounded.tokenizeOwned(resources: resources)
        #expect(owned?.tokens == expected)
        let last = try #require(owned?.tokens.first { $0.token == .identifier("p1023") })
        #expect(last.location.line == 1154 && last.location.column == 5)
        #expect(owned?.tokens.contains { $0.token == .comment("* Standalone tail") } == true)
        // Includes both builders, payload owner slots, geometric growth and removed newline/comment slots.
        // Rebuilding every retained prefix exceeds this linear bound by an order of magnitude.
        #expect(resources.work(.retainedElements) <= UInt64(coefficientCount * 128 + 4096))
        #expect(resources.used(.temporaryBytes) == 0)
        withExtendedLifetime(owned) {}
        owned = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }
}

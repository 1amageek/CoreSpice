import CoreSpiceParsedIR
import CoreSpiceParser
@testable import CoreSpiceParserSPICE
import Synchronization
import Testing

@Suite("Bounded lexer and expression grammar", .timeLimit(.minutes(1)))
struct LexerExpressionOwnedTests {
    @Test func conditionalScopeTokensLocationsAndASTMatchWithReleasedScratch() throws {
        for newline in ["\n", "\r\n"] {
            let source = [".param value={q?v(x:y)", "* ignored ? :", "", "+ :i(vbranch:r)}", "R1 a:b 0 1k"].joined(separator: newline)
            let resources = GrammarTestResources()
            var ordinary = SPICELexer(source: source, fileName: "conditional.sp")
            var bounded = SPICELexer(source: source, fileName: "conditional.sp")
            do {
                let owned = try bounded.tokenizeOwned(resources: resources)
                #expect(owned.tokens == ordinary.tokenize())
                #expect(owned.tokens.contains { $0.token == .identifier("a:b") })
                let colon = try #require(owned.tokens.first { $0.token == .colon })
                #expect(colon.location.line == 4)
                #expect(colon.location.column == 3)
                #expect(resources.used(.temporaryBytes) == 0)
            }
            #expect(resources.used(.liveOwnedBytes) == 0)
            for expression in ["q?a:b", "q?a?b:c:d", "q?a:b?c:d", "q?(a?b:c):d", "q?v(x:y):i(vbranch:r)"] {
                do {
                    var storage = SPICEParseStorage(resources: resources)
                    #expect(try SPICEExpressionParser().parse(expression, storage: &storage)
                        == SPICEExpressionParser().parse(expression))
                    #expect(resources.used(.temporaryBytes) == 0)
                }
                #expect(resources.used(.liveOwnedBytes) == 0)
            }
        }
    }

    @Test func conditionalScopeReservationAndLateCancellationReleaseWhileLexerLives() {
        for point in [2, 3] {
            let resources = ConditionalScopeTestResources(failingTemporaryReservation: point)
            var lexer = SPICELexer(expressionSource: "?", fileName: nil)
            let error = point == 2 ? GrammarTestError.limit(.temporaryBytes) : .cancelled
            #expect(throws: error) { try lexer.tokenizeOwned(resources: resources) }
            #expect(resources.temporaryReservations == point)
            #expect(resources.backing.used(.temporaryBytes) == 0)
            #expect(resources.backing.used(.liveOwnedBytes) == 0)
        }
    }

    @Test func lexerPreservesOrdinaryTokensEscapesAndPhysicalContinuations() throws {
        let source = ".param A='2+max(3,4)' T=\"escaped\\\"text\\\\tail\"\r\n * comment\r\n\r\n + B=2MEG C=4.8.1\r\nR1 n1 0 5mil\r\n"
        var ordinary = SPICELexer(source: source, fileName: "owned.sp")
        var bounded = SPICELexer(source: source, fileName: "owned.sp")
        let resources = GrammarTestResources()
        let owned = try bounded.tokenizeOwned(resources: resources)
        #expect(owned.tokens == ordinary.tokenize())
        #expect(owned.tokens.contains { $0.token == .string("escaped\"text\\tail") })
        let continued = try #require(owned.tokens.first { $0.token == .identifier("b") })
        #expect(continued.location.line == 4)
        #expect(continued.location.column == 4)
        #expect(resources.used(.temporaryBytes) == 0)
        #expect(resources.used(.liveOwnedBytes) > UInt64(source.utf8.count))
    }

    @Test func expressionsAndFormatterPreserveTheActualOrdinaryAST() throws {
        let sources = ["-a+2*3**2", "max(a,min(2,3),4)", "a>1 ? b+2 : c/3", "'2+max(3,4)'", "a .GE. 2 .AND. NOT b", "1meg+5mil", "(a==b)||(a!=c)"]
        let parser = SPICEExpressionParser()
        for source in sources {
            let resources = GrammarTestResources()
            var storage = SPICEParseStorage(resources: resources)
            let ordinary = try parser.parse(source)
            let bounded = try parser.parse(source, storage: &storage)
            #expect(bounded == ordinary)
            #expect(try SPICEAccountedExpressionFormatting.format(bounded, storage: &storage) == ordinary.description)
            #expect(resources.work(.retainedElements) > 0)
            #expect(resources.work(.projectedBytes) > 0)
            #expect(resources.used(.temporaryBytes) == 0)
        }
    }

    @Test func quotedInteriorDiagnosticsKeepOriginalPhysicalFileAndColumn() throws {
        let resources = GrammarTestResources()
        var lexer = SPICELexer(source: ".param a=1\r\n * skipped\r\n + b='2+@'\r\n", fileName: "physical.sp")
        let owned = try lexer.tokenizeOwned(resources: resources)
        let start = try #require(owned.tokens.firstIndex { if case .quotedExpression = $0.token { true } else { false } })
        var parser = SPICEExpressionTokenParser(tokens: owned.tokens, currentIndex: start, work: resources)
        var storage = SPICEParseStorage(resources: resources)
        try storage.hold(owned.storage)
        do {
            _ = try parser.parseExpression(storage: &storage)
            Issue.record("Expected invalid quoted numeric character")
        } catch let diagnostic as ParserDiagnostic {
            #expect(diagnostic.message == "Invalid character in expression")
            #expect(diagnostic.location?.file == "physical.sp")
            #expect(diagnostic.location?.line == 3)
            #expect(diagnostic.location?.column == 9)
        }
    }

    @Test func continuationRefundsDiscardedCommentAndBuilderBacking() throws {
        let baselineResources = GrammarTestResources()
        let commentedResources = GrammarTestResources()
        var baseline = SPICELexer(source: ".param a=1\n+ b=2\n")
        var commented = SPICELexer(source: ".param a=1\n*" + String(repeating: "x", count: 4096) + "\n\n+ b=2\n")
        let first = try baseline.tokenizeOwned(resources: baselineResources)
        let second = try commented.tokenizeOwned(resources: commentedResources)
        #expect(first.tokens.map(\.token) == second.tokens.map(\.token))
        #expect(baselineResources.used(.liveOwnedBytes) == commentedResources.used(.liveOwnedBytes))
        #expect(commentedResources.used(.temporaryBytes) == 0)
        #expect(commentedResources.releaseCount > baselineResources.releaseCount)
    }

    @Test func actualLexerAndExpressionOwnersReleaseOnlyAtTheirFinalCopy() throws {
        let resources = GrammarTestResources()
        var lexer = SPICELexer(source: ".param amplitude=1.25\n")
        var owned: SPICEOwnedTokens? = try lexer.tokenizeOwned(resources: resources)
        var copy = owned
        let live = resources.used(.liveOwnedBytes)
        owned = nil
        #expect(resources.used(.liveOwnedBytes) == live)
        #expect(copy?.tokens.contains { $0.token == .identifier("amplitude") } == true)
        copy = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
        var storage = SPICEParseStorage(resources: resources)
        _ = try SPICEExpressionParser().parse("max(1,a+2)", storage: &storage)
        var finalCopy: SPICEParseStorage? = storage
        let astLive = resources.used(.liveOwnedBytes)
        storage = SPICEParseStorage(resources: resources)
        #expect(resources.used(.liveOwnedBytes) == astLive)
        #expect(finalCopy != nil)
        finalCopy = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func tokenAndTextQuotaRefusalPrecedesActualCopy() throws {
        let slots = GrammarTestResources(temporaryLimit: 0)
        var lexer = SPICELexer(source: "identifier")
        #expect(throws: GrammarTestError.limit(.temporaryBytes)) { try lexer.tokenizeOwned(resources: slots) }
        #expect(slots.work(.projectedBytes) == 0)
        #expect(slots.used(.liveOwnedBytes) == 0)
        let text = GrammarTestResources(liveLimit: 0)
        var another = SPICELexer(source: "identifier")
        #expect(throws: GrammarTestError.limit(.liveOwnedBytes)) { try another.tokenizeOwned(resources: text) }
        #expect(text.work(.projectedBytes) == 0)
        #expect(text.used(.temporaryBytes) == 0)
    }

    @Test func indirectLiteralPayloadAndArgumentSlotsRequireCapacity() throws {
        let resources = GrammarTestResources()
        var lexer = SPICELexer(expressionSource: "max(1,2)", fileName: nil)
        let owned = try lexer.tokenizeOwned(resources: resources)
        let refused = GrammarTestResources(liveLimit: 0)
        var storage = SPICEParseStorage(resources: refused)
        var parser = SPICEExpressionTokenParser(tokens: owned.tokens, currentIndex: 0, work: refused)
        #expect(throws: GrammarTestError.limit(.liveOwnedBytes)) { try parser.parseExpression(storage: &storage) }
        #expect(parser.currentIndex == 3)
        #expect(refused.used(.liveOwnedBytes) == 0)
        #expect(refused.used(.temporaryBytes) == 0)
    }

    @Test func cumulativeWorkAndStorageDoNotResetForSuccessiveExpressions() throws {
        let resources = GrammarTestResources()
        var storage = SPICEParseStorage(resources: resources)
        _ = try SPICEExpressionParser().parse("1+a", storage: &storage)
        let live = resources.used(.liveOwnedBytes)
        let work = resources.work(.lexicalBytes)
        _ = try SPICEExpressionParser().parse("1+a", storage: &storage)
        #expect(resources.used(.liveOwnedBytes) > live)
        #expect(resources.work(.lexicalBytes) > work)
        let refused = GrammarTestResources(workLimit: 8)
        var limited = SPICEParseStorage(resources: refused)
        #expect(throws: GrammarTestError.workLimit) { try SPICEExpressionParser().parse("123+456", storage: &limited) }
        #expect(refused.used(.liveOwnedBytes) == 0)
        #expect(refused.used(.temporaryBytes) == 0)
    }

    @Test func longDotTokenChecksCancellationDuringActualScanning() throws {
        let resources = CancelDuringLexerResources()
        var lexer = SPICELexer(source: "." + String(repeating: "a", count: 16384))
        #expect(throws: GrammarTestError.cancelled) { try lexer.tokenizeOwned(resources: resources) }
        #expect(resources.scanningChecks >= 40)
        #expect(resources.backing.used(.liveOwnedBytes) == 0)
        #expect(resources.backing.used(.temporaryBytes) == 0)
    }

    @Test func unsupportedUnicodeAndOversizeScalarRefuseBeforeOpaqueConversion() throws {
        let resources = GrammarTestResources()
        var lexer = SPICELexer(source: ".param caf\u{00E9}=1")
        #expect(throws: SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode SPICE lexing")) {
            try lexer.tokenizeOwned(resources: resources)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
        let scalar = "0." + String(repeating: "0", count: 70) + "1"
        var ordinary = SPICELexer(expressionSource: scalar, fileName: nil)
        #expect(ordinary.tokenize().first?.token == .number(1e-71))
        var bounded = SPICELexer(expressionSource: scalar, fileName: nil)
        #expect(throws: SPICEBoundedSourceError.unsupportedBudgetCapability("Scalar decimal conversion beyond 64 ASCII bytes")) {
            try bounded.tokenizeOwned(resources: resources)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        var storage = SPICEParseStorage(resources: resources)
        #expect(throws: SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode expression formatting")) {
            try SPICEAccountedExpressionFormatting.format(.identifier("caf\u{00E9}"), storage: &storage)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func scalarFormatterPreservesBackendExtremesAndRequiresScratchBeforeFormatting() throws {
        let resources = GrammarTestResources()
        var storage = SPICEParseStorage(resources: resources)
        for value in [Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude, -Double.greatestFiniteMagnitude, -0.0, .infinity, -.infinity, .nan] {
            let expression = ParsedExpression.literal(value)
            #expect(try SPICEAccountedExpressionFormatting.format(expression, storage: &storage) == expression.description)
        }
        #expect(resources.used(.temporaryBytes) == 0)
        let refused = GrammarTestResources(temporaryLimit: 63)
        var limited = SPICEParseStorage(resources: refused)
        #expect(throws: GrammarTestError.limit(.temporaryBytes)) {
            try SPICEAccountedExpressionFormatting.format(.literal(1.0), storage: &limited)
        }
        #expect(refused.work(.projectedBytes) == 0)
    }
}

private final class CancelDuringLexerResources: SPICESourceResourceAccounting {
    let backing = GrammarTestResources()
    private struct State { var scanning = false; var checks = 0 }
    private let state = Mutex(State())
    var scanningChecks: Int { state.withLock { $0.checks } }
    func checkCancellation() throws {
        let cancelled = state.withLock { value in
            if value.scanning { value.checks += 1 }
            return value.checks >= 40
        }
        if cancelled { throw GrammarTestError.cancelled }
        try backing.checkCancellation()
    }
    func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
        if kind == .tokens { state.withLock { $0.scanning = true } }
        try backing.charge(kind, units: units)
    }
    func chargeHashedBytes(_ byteCount: UInt64) throws { try backing.chargeHashedBytes(byteCount) }
    func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
        try checkCancellation()
        return try backing.reserveStorage(kind: kind, byteCount: byteCount)
    }
}

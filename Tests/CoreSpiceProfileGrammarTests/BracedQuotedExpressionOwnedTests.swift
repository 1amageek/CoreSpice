import CoreSpiceParsedIR
import CoreSpiceParser
@testable import CoreSpiceParserSPICE
import Synchronization
import Testing

@Suite("Bounded model braced numeric quote elision", .timeLimit(.minutes(1)))
struct BracedQuotedExpressionOwnedTests {
    @Test func projectedCaseSensitiveModelMatchesOrdinaryAndReleasesOwnership() async throws {
        let source = "Projected model\n.model rm r rsh={\"A\"\n.if 0\n+ +ignored\n.endif\n+ +B}\n.end\n"
        let configuration = ParserConfiguration(caseInsensitive: false, resolveIncludes: true)
        let ordinary = try await SPICEParser().parse(source: source, configuration: configuration).get()
        let resources = GrammarTestResources()
        do {
            let result = try await parse(source, resources: resources, configuration: configuration)
            #expect(result.netlist.models.map(\.parameters) == ordinary.models.map(\.parameters))
            #expect(result.netlist.models.first?.parameters["rsh"] == .expression(.binaryOperation(.add,
                .identifier("A"), .identifier("B"))))
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func mixedSingleQuotesRefuseAndReleaseOwnedSource() async throws {
        let source = "Mixed quote ownership\n.model rm r rsh={\"1\"+'2'}\n.end\n"
        let ordinary = await SPICEParser().parse(source: source, fileName: "model-profile")
        let resources = GrammarTestResources()
        do {
            _ = try await parse(source, resources: resources)
            Issue.record("Mixed quotes became numerical success")
        } catch let failure as SPICEProfileParseFailure {
            #expect(failure.diagnostic.message.contains("Single-quoted substrings"))
            #expect(failure.diagnostic.location == ordinary.errors.first?.location)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test(arguments: ["\n", "\r\n"])
    func ordinaryAndOwnedModelsMatchAcrossPhysicalContinuations(newline: String) async throws {
        let text = ["Owned model quotes", ".if 0", ".model hidden r dw={\"ignored\"}", ".endif",
            ".model rm r dw={\"-tol_nfom/2-nfom_dw/2\"} rsh={2*\"a+b\"}",
            "+ dl={\"q?\"v(x:y)", "* interrupted continuation", "", "+ :i(branch:r)}",
            "+ tc1={", "* continuation before first expression token", "+ \"a\"+b}", ".end", ""].joined(separator: newline)
        let ordinary = try await SPICEParser().parse(source: text, fileName: "model-profile").get()
        let resources = GrammarTestResources()
        do {
            let result = try await parse(text, resources: resources)
            #expect(result.netlist.models.map(\.parameters) == ordinary.models.map(\.parameters))
            #expect(result.netlist.models.first?.parameters["dl"] == .expression(.conditional(
                condition: .identifier("q"),
                then: .functionCall(name: "v", arguments: [.identifier("x:y")]),
                else: .functionCall(name: "i", arguments: [.identifier("branch:r")]))))
            #expect(resources.work(.lexicalBytes) > UInt64(text.utf8.count))
            #expect(resources.used(.liveOwnedBytes) > 0)
            #expect(resources.used(.temporaryBytes) == 0)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test(arguments: ["\n", "\r\n"])
    func rawFailuresMatchOrdinaryPhysicalLocationsAndReleaseOwners(newline: String) async throws {
        for (interior, marker) in [(#"1"k""#, "k"), (#""a+@""#, "@"), (#""a\"+b""#, "\\"),
                                   (#""""#, "}"), (#"2*"""#, "}")] {
            let card = "  + dw={\(interior)}"
            let text = ["Owned malformed model", ".model rm r rsh=1", "* interruption", "", card, ".end", ""].joined(separator: newline)
            let ordinary = await SPICEParser().parse(source: text, fileName: "model-profile")
            let markerIndex = try #require(card.range(of: marker)?.lowerBound)
            let expected = SourceLocation(file: "model-profile", line: 5,
                column: card.distance(from: card.startIndex, to: markerIndex) + 1)
            #expect(ordinary.errors.first?.location == expected)
            let resources = GrammarTestResources()
            do {
                _ = try await parse(text, resources: resources)
                Issue.record("Expected model interior refusal")
            } catch let failure as SPICEProfileParseFailure {
                #expect(failure.diagnostic.location == expected)
            }
            #expect(resources.used(.liveOwnedBytes) == 0)
            #expect(resources.used(.temporaryBytes) == 0)
        }
    }

    @Test func rawSpanScannerUsesAdmittedStorageAndReleasesOnLateCancellation() throws {
        let text = #"prefix {"a+b"} suffix"#
        let lower = try #require(text.firstIndex(of: "{"))
        let upper = try #require(text.firstIndex(of: "}"))
        let opening = SourceLocation(file: "raw-span", line: 7, column: 8)
        let refused = GrammarTestResources(temporaryLimit: 0)
        var refusedLexer = SPICELexer(modelExpressionSource: text, range: lower..<upper, opening: opening)
        #expect(throws: GrammarTestError.limit(.temporaryBytes)) {
            try refusedLexer.tokenizeOwned(resources: refused)
        }
        #expect(refused.work(.projectedBytes) == 0)
        #expect(refused.used(.liveOwnedBytes) == 0)
        #expect(refused.used(.temporaryBytes) == 0)

        let cancelled = ModelQuoteCancellationResources()
        var cancelledLexer = SPICELexer(modelExpressionSource: text, range: lower..<upper, opening: opening)
        #expect(throws: GrammarTestError.cancelled) {
            try cancelledLexer.tokenizeOwned(resources: cancelled)
        }
        #expect(cancelled.liveReservations == 2)
        #expect(cancelled.backing.used(.liveOwnedBytes) == 0)
        #expect(cancelled.backing.used(.temporaryBytes) == 0)

        let admitted = GrammarTestResources()
        var ordinary = SPICELexer(modelExpressionSource: text, range: lower..<upper, opening: opening)
        var bounded = SPICELexer(modelExpressionSource: text, range: lower..<upper, opening: opening)
        do {
            let tokens = try bounded.tokenizeOwned(resources: admitted)
            #expect(tokens.tokens == ordinary.tokenize())
            #expect(tokens.tokens.first?.location == opening)
            #expect(admitted.used(.temporaryBytes) == 0)
        }
        #expect(admitted.used(.liveOwnedBytes) == 0)
    }

    private func parse(_ text: String, resources: GrammarTestResources,
                       configuration: ParserConfiguration = ParserConfiguration(resolveIncludes: true)) async throws -> SPICEOwnedParseResult {
        let document = try SPICESourceDocument(accountedText: SPICEAccountedText.copy(text, resources: resources,
            maximumChunkByteCount: 256), sourceKey: "model-profile", occurrenceID: .init(0), resolvedPath: "model-profile")
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "model-quotes",
            configuration: configuration, resources: resources, maximumPageByteCount: 256)
        return try await SPICEParser().parseProfile(document: document, configuration: configuration,
            environment: environment, resolver: ModelQuoteNoDependencyResolver(), resources: resources)
    }
}

private struct ModelQuoteNoDependencyResolver: SPICEContextualFileResolver {
    func resolve(_ request: SPICESourceDependencyRequest) async throws -> SPICESourceDocument {
        throw ParserDiagnostic.error("Unexpected model quote fixture dependency")
    }
}

private final class ModelQuoteCancellationResources: SPICESourceResourceAccounting {
    let backing = GrammarTestResources()
    private let reservations = Mutex(0)
    var liveReservations: Int { reservations.withLock { $0 } }
    func checkCancellation() throws { try backing.checkCancellation() }
    func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws { try backing.charge(kind, units: units) }
    func chargeHashedBytes(_ byteCount: UInt64) throws { try backing.chargeHashedBytes(byteCount) }
    func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
        let receipt = try backing.reserveStorage(kind: kind, byteCount: byteCount)
        if kind == .liveOwnedBytes {
            let count = reservations.withLock { value in value += 1; return value }
            if count == 2 { backing.setCancelled(true) }
        }
        return receipt
    }
}

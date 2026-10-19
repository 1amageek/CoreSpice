import CoreSpiceParsedIR
import CoreSpiceParser
@testable import CoreSpiceParserSPICE
import Synchronization
import Testing

@Suite("Accounted card symbol roles", .timeLimit(.minutes(1)))
struct CardSymbolOwnedTests {
    @Test func originalNodesAndPhysicalContinuationMatchOrdinaryGrammar() async throws {
        let source = "Symbols\r\n.subckt cell-0/CLK# CLK Q\r\n"
            + "X0 a_891_413# a_193_47# a_975_413# VPB sky130_fd_pr__pfet_01v8_hvt w=420000u l=150000u\r\n"
            + ".ends cell-0/CLK#\r\nXCell-0/CLK# cts_net-4_cell-0/CLK:A\r\n* unchanged comment\r\n"
            + "+ port-0-0 cell-0/CLK# p={a-b/c}\r\n.model model-a/b# nmos level=54 version=4.50\r\n.end\r\n"
        let ordinary = try await SPICEParser().parse(document: .init(text: source, resolvedPath: "symbols.sp"),
            configuration: .default, fileResolver: NullFileResolver()).get()
        let resources = GrammarTestResources()
        do {
            let owned = try await parse(source, resources: resources)
            expectComponentSemanticParity(owned: owned.netlist.components, ordinary: ordinary.components)
            expectComponentSemanticParity(owned: owned.netlist.subcircuits[0].body.components,
                ordinary: ordinary.subcircuits[0].body.components)
            let element = try #require(owned.netlist.components.first)
            #expect(element.nodes.map(\.name) == ["cts_net-4_cell-0/clk:a", "port-0-0"])
            #expect(element.modelName == "cell-0/clk#")
            let prefix = "Symbols\r\n.subckt cell-0/CLK# CLK Q\r\n"
                + "X0 a_891_413# a_193_47# a_975_413# VPB sky130_fd_pr__pfet_01v8_hvt w=420000u l=150000u\r\n"
                + ".ends cell-0/CLK#\r\n"
            #expect(element.origin?.statementByteOffset == UInt64(prefix.utf8.count))
            #expect(element.nodes[1].location?.line == 7)
            #expect(owned.netlist.models[0].name == "model-a/b#")
            #expect(owned.netlist.models[0].parameters["version"] == .string("4.50"))
            #expect(resources.used(.temporaryBytes) == 0)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func lexerAndExpressionOperatorsRemainUnchanged() throws {
        let source = "q?a-b:c/d"
        var ordinary = SPICELexer(source: source)
        let expected = ordinary.tokenize()
        let resources = GrammarTestResources()
        do {
            var lexer = SPICELexer(source: source)
            let owned = try lexer.tokenizeOwned(resources: resources)
            #expect(owned.tokens == expected)
            #expect(expected.contains { $0.token == .minus })
            #expect(expected.contains { $0.token == .slash })
            #expect(expected.contains { $0.token == .colon })
            var storage = SPICEParseStorage(resources: resources)
            #expect(try SPICEExpressionParser().parse(source, storage: &storage)
                == SPICEExpressionParser().parse(source))
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test(arguments: ["F1 out 0 VCTRL 1e+3", "H1 out 0 VCTRL 1e+3", "R1 1e+3 0 1k"])
    func numericExponentPlusPreservesAccountedMeaningAndRefund(card: String) async throws {
        let resources = GrammarTestResources()
        do {
            let owned = try await parse("Numeric token extent\n\(card)\n.end\n", resources: resources)
            let element = try #require(owned.netlist.components.first)
            if card.hasPrefix("R") {
                #expect(element.nodes.map(\.name) == ["1000", "0"])
                #expect(element.parameters["r"] == .numeric(1000))
            } else {
                #expect(element.nodes.map(\.name) == ["out", "0"])
                #expect(element.parameters["control_source"] == .string("vctrl"))
                #expect(element.parameters[card.hasPrefix("F") ? "f" : "h"] == .numeric(1000))
            }
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test(arguments: [false, true]) func paramsPrefixPreservesAccountedPortsAndNodes(port: Bool) async throws {
        let resources = GrammarTestResources()
        let body = port
            ? ".subckt cell params-0 params/branch#\n.ends cell"
            : "X1 params-0 params/branch# cell"
        do {
            let owned = try await parse("Complete keyword boundary\n\(body)\n.end\n", resources: resources)
            if port {
                #expect(owned.netlist.subcircuits.first?.ports == ["params-0", "params/branch#"])
            } else {
                #expect(owned.netlist.components.first?.nodes.map(\.name) == ["params-0", "params/branch#"])
                #expect(owned.netlist.components.first?.modelName == "cell")
            }
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func controlledLookaheadWorkRemainsLinearInTailLength() async throws {
        func measuredWork(fields: Int) async throws -> UInt64 {
            let resources = GrammarTestResources()
            let tail = Array(repeating: "n", count: fields).joined(separator: " ")
            do {
                _ = try await parse("Lookahead work\nF1 out 0 VCTRL \(tail)\n.end\n", resources: resources)
            } catch is SPICEProfileParseFailure {
                // This test owns bounded lookahead work, not additional tail-arity admission.
            }
            #expect(resources.used(.liveOwnedBytes) == 0)
            #expect(resources.used(.temporaryBytes) == 0)
            return resources.work(.lexicalBytes)
        }
        let small = try await measuredWork(fields: 256)
        let large = try await measuredWork(fields: 512)
        #expect(small > 0)
        #expect(large <= small * 3)
    }

    @Test func malformedXTailIsLocatedAndRefundsOwnedStorage() async throws {
        let resources = GrammarTestResources()
        do {
            _ = try await parse("Bad X tail\nX1 a-0/b# 0 model-a/b# p=1 @\n.end\n", resources: resources)
            Issue.record("Malformed X tail published an owned netlist")
        } catch let error as SPICEProfileParseFailure {
            #expect(error.diagnostic.location?.file == "symbols.sp")
            #expect(error.diagnostic.location?.line == 2)
            #expect(error.diagnostic.location?.column == 28)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test(arguments: [false, true]) func compoundSymbolReservationAndCancellationRefund(cancel: Bool) async throws {
        let symbol = String(repeating: "a", count: 2049) + "-#/" + String(repeating: "b", count: 2053)
        let resources = CardSymbolFailureResources(symbolBytes: UInt64(symbol.utf8.count), cancel: cancel)
        do {
            _ = try await parse("Symbol resource\nR1 \(symbol) 0 1k\n.end\n", resources: resources)
            Issue.record("Compound symbol resource failure was ignored")
        } catch let error as GrammarTestError {
            #expect(error == (cancel ? .cancelled : .limit(.liveOwnedBytes)))
        }
        #expect(resources.triggered)
        #expect(resources.backing.used(.liveOwnedBytes) == 0)
        #expect(resources.backing.used(.temporaryBytes) == 0)
    }

    private func parse(_ source: String, resources: any SPICESourceResourceAccounting) async throws -> SPICEOwnedParseResult {
        let document = try SPICESourceDocument(accountedText: SPICEAccountedText.copy(source,
            resources: resources, maximumChunkByteCount: 256), sourceKey: "symbols.sp",
            occurrenceID: .init(0), resolvedPath: "symbols.sp")
        let configuration = ParserConfiguration(resolveIncludes: true)
        let environment = try SPICEPreprocessingEnvironment.empty(policyIdentity: "card-symbol-test",
            configuration: configuration, resources: resources, maximumPageByteCount: 256)
        return try await SPICEParser().parseProfile(document: document, configuration: configuration,
            environment: environment, resolver: CardSymbolNoDependencyResolver(), resources: resources)
    }
}

private struct CardSymbolNoDependencyResolver: SPICEContextualFileResolver {
    func resolve(_ request: SPICESourceDependencyRequest) async throws -> SPICESourceDocument {
        throw ParserDiagnostic.error("Unexpected dependency in card symbol fixture")
    }
}

private final class CardSymbolFailureResources: SPICESourceResourceAccounting {
    let backing = GrammarTestResources()
    private let fired = Mutex(false)
    private let symbolBytes: UInt64
    private let cancel: Bool
    init(symbolBytes: UInt64, cancel: Bool) { self.symbolBytes = symbolBytes; self.cancel = cancel }
    var triggered: Bool { fired.withLock { $0 } }
    func checkCancellation() throws {
        try backing.checkCancellation()
        if cancel && triggered { throw GrammarTestError.cancelled }
    }
    func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
        if cancel && kind == .projectedBytes && units == symbolBytes {
            fired.withLock { $0 = true }; throw GrammarTestError.cancelled
        }
        try checkCancellation(); try backing.charge(kind, units: units)
    }
    func chargeHashedBytes(_ bytes: UInt64) throws { try backing.chargeHashedBytes(bytes) }
    func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
        if !cancel && kind == .liveOwnedBytes && byteCount == symbolBytes {
            fired.withLock { $0 = true }; throw GrammarTestError.limit(.liveOwnedBytes)
        }
        try checkCancellation(); return try backing.reserveStorage(kind: kind, byteCount: byteCount)
    }
}

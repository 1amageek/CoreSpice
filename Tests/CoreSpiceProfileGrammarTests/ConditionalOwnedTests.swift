import CoreSpiceParsedIR
import CoreSpiceParser
@testable import CoreSpiceParserSPICE
import Synchronization
import Testing

@Suite("Owned conditional preprocessing")
struct ConditionalOwnedTests {
    @Test func checkedInitialEnvironmentSelectsActualBranchAndPhysicalLocations() throws {
        let source = "* deck\r\n  .if MODE == 2\r\nRyes a 0 1k\r\n.else\r\nRno a 0 2k\r\n.endif\r\n"
        let resources = GrammarTestResources()
        let result = try owned(source, parameters: [.init(name: "MODE", expression: "2")], resources: resources)
        let ordinary = try SPICEConditionalPreprocessor().process(source: source, fileName: "deck.sp", initialParameters: ["MODE": "2"])
        #expect(result.source == ordinary.source)
        #expect(result.events == ordinary.events)
        #expect(result.source.contains("Ryes a 0 1k"))
        #expect(!result.source.contains("Rno"))
        #expect(result.events.first?.location?.line == 2)
        #expect(result.events.first?.location?.column == 3)
        #expect(result.storage != nil)
        #expect(ordinary.storage == nil)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func parameterFunctionAndContinuedSubcircuitScopesMatchOrdinary() throws {
        let source = """
        .param scale=2
        .func twice(x) {x*scale}
        .if twice(2) == 4
        Rroot a 0 1k
        .endif
        .subckt local a 0 params: scale=3
        * continuation trivia
        + extra={scale+1}
        .func twice(x) {x+scale}
        .if twice(extra) == 7
        Rlocal a 0 2k
        .endif
        .param scale=5
        .if twice(extra) == 11
        Rchanged a 0 3k
        .endif
        .ends
        .if twice(2) == 4
        Rrestored a 0 4k
        .endif
        """
        let resources = GrammarTestResources()
        let result = try owned(source, resources: resources)
        let ordinary = try SPICEConditionalPreprocessor().process(source: source, fileName: "deck.sp")
        #expect(result.source == ordinary.source)
        #expect(result.events == ordinary.events)
        #expect(result.diagnostics.isEmpty)
        for name in ["Rroot", "Rlocal", "Rchanged", "Rrestored"] { #expect(result.source.contains(name)) }
        #expect(resources.work(.conditionalEvaluations) > 4)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func unresolvedActiveConditionCannotAppearAsResolvedSuccess() throws {
        let source = ".if absent\nRunknown a 0 1k\n.else\nRfallback a 0 2k\n.endif"
        let result = try owned(source, resources: GrammarTestResources())
        #expect(result.events.first?.selection == .unresolved)
        #expect(result.diagnostics.contains { $0.severity == .error && $0.message.contains("Unknown conditional parameter") })
        #expect(!result.source.contains("Runknown"))
        #expect(!result.source.contains("Rfallback"))
    }

    @Test func inactiveNestedConditionsDoNotEvaluateUnknownParameters() throws {
        let source = ".if 0\n.if absent\nRskip a 0 1\n.endif\n.elseif 1\nRyes a 0 2\n.endif"
        let result = try owned(source, resources: GrammarTestResources())
        let ordinary = try SPICEConditionalPreprocessor().process(source: source, fileName: "deck.sp")
        #expect(result.events == ordinary.events)
        #expect(result.diagnostics.isEmpty)
        #expect(result.source.contains("Ryes"))
        #expect(!result.source.contains("Rskip"))
    }

    @Test func functionDefinitionsRemainFreshAcrossSeparateOwnedDocuments() throws {
        let parent = try owned(".func local(x) {x+1}\n.if local(1)==2\nRyes a 0 1\n.endif", resources: GrammarTestResources())
        let child = try owned(".if local(1)==2\nRno a 0 1\n.endif", resources: GrammarTestResources())
        #expect(parent.diagnostics.isEmpty)
        #expect(parent.source.contains("Ryes"))
        #expect(child.events.first?.selection == .unresolved)
        #expect(child.diagnostics.first?.message.contains("Unsupported conditional function") == true)
    }

    @Test func recursiveParametersAndFunctionsProduceOwnedFailureDiagnostics() throws {
        for source in [".param a={b} b={a}\n.if a\nRno a 0 1\n.endif", ".func loop(x) {loop(x)}\n.if loop(1)\nRno a 0 1\n.endif"] {
            let resources = GrammarTestResources()
            let result = try owned(source, resources: resources)
            #expect(result.events.first?.selection == .unresolved)
            #expect(result.diagnostics.first?.message.contains("Recursive conditional") == true)
            #expect(!result.source.contains("Rno"))
            #expect(resources.used(.temporaryBytes) == 0)
        }
    }

    @Test func missingAndUnterminatedConditionsPreserveOrdinaryDiagnostics() throws {
        let source = ".else\n.if\n.elseif 1\n.else\n.elseif 1\n"
        let result = try owned(source, resources: GrammarTestResources())
        let ordinary = try SPICEConditionalPreprocessor().process(source: source, fileName: "deck.sp")
        #expect(result.source == ordinary.source)
        #expect(result.events == ordinary.events)
        #expect(result.diagnostics.map(\.message) == ordinary.diagnostics.map(\.message))
        #expect(result.diagnostics.map(\.location) == ordinary.diagnostics.map(\.location))
    }

    @Test func storageFailureAndCancellationPropagateActualTypedCause() throws {
        let inputResources = GrammarTestResources()
        let document = try document(".if 1\nRyes a 0 1\n.endif", resources: inputResources)
        let environment = try environment(resources: inputResources)
        let denied = GrammarTestResources(liveLimit: 0)
        #expect(throws: GrammarTestError.limit(.liveOwnedBytes)) {
            try SPICEConditionalPreprocessor().processOwned(document: document, environment: environment, resources: denied)
        }
        #expect(denied.used(.liveOwnedBytes) == 0)
        #expect(denied.used(.temporaryBytes) == 0)
        let cancelled = GrammarTestResources()
        cancelled.setCancelled(true)
        #expect(throws: GrammarTestError.cancelled) {
            try SPICEConditionalPreprocessor().processOwned(document: document, environment: environment, resources: cancelled)
        }
        #expect(cancelled.used(.liveOwnedBytes) == 0)
    }

    @Test func cumulativeWorkAndLongHelperScansRefuseWithoutUnknownErrorSuccess() throws {
        let source = ".param long={" + String(repeating: "1+", count: 1024) + "1}\n.if long\nRyes a 0 1\n.endif"
        let inputResources = GrammarTestResources()
        let document = try document(source, resources: inputResources)
        let environment = try environment(resources: inputResources)
        let limited = GrammarTestResources(workLimit: 4000)
        #expect(throws: GrammarTestError.workLimit) {
            try SPICEConditionalPreprocessor().processOwned(document: document, environment: environment, resources: limited)
        }
        #expect(limited.used(.liveOwnedBytes) == 0)
        #expect(limited.used(.temporaryBytes) == 0)
        let resources = ConditionalCancellingResources(cancelAtLexicalBytes: UInt64(source.utf8.count * 4))
        #expect(throws: GrammarTestError.cancelled) {
            try SPICEConditionalPreprocessor().processOwned(document: document, environment: environment, resources: resources)
        }
        #expect(resources.base.used(.liveOwnedBytes) == 0)
        #expect(resources.base.used(.temporaryBytes) == 0)
    }

    @Test func resultCopyRetainsActualSourceAndFactsUntilFinalOwnerRelease() throws {
        let resources = GrammarTestResources()
        var result: SPICEConditionalPreprocessor.Result? = try owned(".if 1\nRowned a 0 1\n.endif", resources: resources)
        #expect(resources.used(.temporaryBytes) == 0)
        let live = resources.used(.liveOwnedBytes)
        #expect(live > 0)
        #expect(resources.peakLiveBytes > live)
        var copy = result
        result = nil
        #expect(copy?.source.contains("Rowned") == true)
        #expect(copy?.events.first?.active == true)
        #expect(copy?.storage != nil)
        #expect(resources.used(.liveOwnedBytes) == live)
        copy = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func unownedAndUnsupportedUnicodeSourcesFailBeforeGrammarOperation() throws {
        let resources = GrammarTestResources()
        let environment = try environment(resources: resources)
        #expect(throws: SPICEBoundedSourceError.unaccountedSource) {
            try SPICEConditionalPreprocessor().processOwned(document: SPICESourceDocument(text: ".if 1"), environment: environment, resources: resources)
        }
        let baseline = resources.used(.liveOwnedBytes)
        let unicode = try document(".param café=1\n.if café\nRyes a 0 1\n.endif", resources: resources)
        let unicodeBaseline = resources.used(.liveOwnedBytes)
        #expect(throws: SPICEBoundedSourceError.unsupportedBudgetCapability("Cooperative Unicode conditional processing")) {
            try SPICEConditionalPreprocessor().processOwned(document: unicode, environment: environment, resources: resources)
        }
        #expect(resources.used(.liveOwnedBytes) == unicodeBaseline)
        #expect(unicodeBaseline > baseline)
        let ordinary = try SPICEConditionalPreprocessor().process(source: unicode.text, fileName: "deck.sp")
        #expect(ordinary.source.contains("Ryes"))
    }

    private func owned(_ source: String, parameters: [SPICEPreprocessingParameter] = [],
                       resources: GrammarTestResources) throws -> SPICEConditionalPreprocessor.Result {
        try SPICEConditionalPreprocessor().processOwned(document: document(source, resources: resources),
            environment: environment(parameters: parameters, resources: resources), resources: resources)
    }
    private func document(_ source: String, resources: any SPICESourceResourceAccounting) throws -> SPICESourceDocument {
        let text = try SPICEAccountedText.copy(source, resources: resources, maximumChunkByteCount: 256)
        return try SPICESourceDocument(accountedText: text, sourceKey: "fixture", occurrenceID: .init(1), resolvedPath: "deck.sp")
    }
    private func environment(parameters: [SPICEPreprocessingParameter] = [],
                             resources: any SPICESourceResourceAccounting) throws -> SPICEPreprocessingEnvironment {
        try .admit(parameters: parameters, policyIdentity: "conditional-test-1", configuration: ParserConfiguration(resolveIncludes: true),
                   resources: resources, maximumPageByteCount: 256)
    }
}

private final class ConditionalCancellingResources: SPICESourceResourceAccounting {
    let base = GrammarTestResources()
    private let lexical = Mutex<UInt64>(0)
    private let cancelAtLexicalBytes: UInt64
    init(cancelAtLexicalBytes: UInt64) { self.cancelAtLexicalBytes = cancelAtLexicalBytes }
    func checkCancellation() throws { try base.checkCancellation() }
    func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {
        try base.charge(kind, units: units)
        if kind == .lexicalBytes {
            let value = lexical.withLock { value in value += units; return value }
            if value >= cancelAtLexicalBytes { base.setCancelled(true) }
        }
    }
    func chargeHashedBytes(_ byteCount: UInt64) throws { try base.chargeHashedBytes(byteCount) }
    func reserveStorage(kind: SPICESourceStorageKind, byteCount: UInt64) throws -> SPICESourceStorageReservation {
        try base.reserveStorage(kind: kind, byteCount: byteCount)
    }
}

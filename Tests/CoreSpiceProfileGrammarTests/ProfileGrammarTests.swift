import CoreSpiceParsedIR
import CoreSpiceParser
@testable import CoreSpiceParserSPICE
import Testing

@Suite("Contextual bounded profile grammar")
struct ProfileGrammarTests {
    private let configuration = ParserConfiguration(resolveIncludes: true)

    @Test func boundedNamedResistanceMatchesOrdinaryASTAndReleasesOwners() async throws {
        let resources = GrammarTestResources()
        let text = """
        R0 r0 r1 r=rspwres*((l+dl)/w)*(1-av*(max(v(r0),v(r1))-min(v(r0),v(r1))))*
        + (1+bv*(v(b)-min(v(r0),v(r1))))*(1+local_vt*(temper-tref)+ut*(temper-tref)*(temper-tref)) tc1=.01 m=2 noisy=0
        """
        let ordinary = try await SPICEParser().parse(source: "bounded reference\n" + text).get()
        do {
            let document = try source("bounded reference\n" + text, key: "runtime-resistor", occurrence: 0, resources)
            let resolver = FixtureResolver(resources: resources, sources: [:])
            let result = try await SPICEParser().parseProfile(document: document, configuration: configuration,
                environment: empty(resources), resolver: resolver, resources: resources)
            #expect(result.netlist.components.first?.parameters == ordinary.components.first?.parameters)
            #expect(resources.work(.retainedElements) > 0)
            #expect(resources.used(.liveOwnedBytes) > 0)
            #expect(resources.used(.temporaryBytes) == 0)
        }
        #expect(resources.used(.liveOwnedBytes) == 0)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func requestPrecedesChildParsingAndCarriesActualInheritedSnapshot() async throws {
        let resources = GrammarTestResources()
        let environment = try empty(resources)
        let root = try source(".param mode=1\r\n.include child.sp\r\n", key: "root", occurrence: 0, resources)
        let resolver = FixtureResolver(resources: resources,
            sources: ["child.sp": ".if mode==1\n.model selected nmos\n.else\n.model inactive pmos\n.endif\n"])
        let result = try await SPICEParser().parseProfile(document: root, configuration: configuration,
            environment: environment, resolver: resolver, resources: resources)
        let requests = await resolver.requests()
        let request = try #require(requests.first)
        let expected = try environment.inheriting(replacing: [.init(name: "mode", expression: "1.0")],
            resources: resources, maximumPageByteCount: 256)
        #expect(request.environment.identity == expected.identity)
        #expect(request.parentSourceKey == "root")
        #expect(request.parentOccurrenceID.rawValue == 0)
        #expect(request.statementByteOffset == 15)
        #expect(request.statementOrdinal == 1)
        #expect(result.netlist.models.map(\.name) == ["selected"])
        #expect(result.netlist.models.first?.origin?.occurrenceID?.rawValue == 1)
        #expect(result.netlist.models.first?.origin?.statementByteOffset == 12)
        #expect(result.netlist.dependencyEvents.first?.preprocessingIdentity == expected.identity)
        #expect(resources.used(.temporaryBytes) == 0)
    }

    @Test func selectedParentIncludesFullChildAndExternalLibraryKeepsActualChildSection() async throws {
        let resources = GrammarTestResources()
        let full = try source(".lib slow\r\n.include child.sp\r\n.lib external.sp fast\r\n.endl slow\r\n", key: "root", occurrence: 0, resources)
        let selected = try full.selectingLibrarySection("slow", resources: resources)
        let resolver = FixtureResolver(resources: resources, sources: ["child.sp": ".model full nmos\n",
            "external.sp": ".lib fast\n.model fast nmos\n.endl fast\n.lib slow\n.model unused pmos\n.endl slow\n"])
        let result = try await SPICEParser().parseProfile(document: selected, configuration: configuration,
            environment: empty(resources), resolver: resolver, resources: resources)
        let events = result.netlist.dependencyEvents
        #expect(events.count == 2)
        #expect(events[0].parentSection == "slow")
        #expect(events[0].selectedSection == nil)
        #expect(events[0].statementByteOffset == 11)
        #expect(events[1].selectedSection == "fast")
        #expect(result.netlist.models.map(\.name) == ["full", "fast"])
    }

    @Test func repeatedContentAndNestedEdgesKeepDistinctOccurrencesAndLexicalOrder() async throws {
        let resources = GrammarTestResources()
        let root = try source(".include child.sp\n.include child.sp\n", key: "root", occurrence: 0, resources)
        let resolver = FixtureResolver(resources: resources, sources: ["child.sp": ".model same nmos\n.include grand.sp\n",
            "grand.sp": ".subckt box a b\nR1 a b 1k\n.ends\n"])
        let result = try await SPICEParser().parseProfile(document: root, configuration: configuration,
            environment: empty(resources), resolver: resolver, resources: resources)
        #expect(result.netlist.dependencyEvents.map(\.ordinal) == [0, 1, 2, 3])
        #expect(result.netlist.dependencyEvents.map { $0.parentOccurrenceID?.rawValue } == [0, 1, 0, 3])
        #expect(result.netlist.dependencyEvents.map { $0.childOccurrenceID?.rawValue } == [1, 2, 3, 4])
        #expect(result.netlist.models.map { $0.origin?.occurrenceID?.rawValue } == [1, 3])
        #expect(result.netlist.subcircuits.map { $0.origin?.occurrenceID?.rawValue } == [2, 4])
        #expect(result.netlist.subcircuits.map { $0.origin?.statementByteOffset } == [0, 0])
    }

    @Test func childEntryExcludesParentFunctionsAndHeaderDefaultsAndParentBranchesStayFixed() async throws {
        let resources = GrammarTestResources()
        let root = try source(".param mode=0\n.include definitions\n.if mode==1\n.model inactive nmos\n.endif\n", key: "root", occurrence: 0, resources)
        let resolver = FixtureResolver(resources: resources, sources: ["definitions": ".param mode=1\n"])
        let result = try await SPICEParser().parseProfile(document: root, configuration: configuration,
            environment: empty(resources), resolver: resolver, resources: resources)
        #expect(result.netlist.models.isEmpty)
        #expect(result.netlist.parameters["mode"] == .literal(1))
        for text in [".func parent(x) {x+1}\n.include conditional\n",
                     ".subckt box a b params: parent=1\n.include conditional\n.ends\n"] {
            let parent = try source(text, key: "root", occurrence: 0, resources)
            let child = text.hasPrefix(".func") ? ".if parent(1)==2\n.model unused nmos\n.endif\n" : ".if parent==1\n.model unused nmos\n.endif\n"
            let missing = FixtureResolver(resources: resources, sources: ["conditional": child])
            do {
                _ = try await SPICEParser().parseProfile(document: parent, configuration: configuration,
                    environment: empty(resources), resolver: missing, resources: resources)
                Issue.record("Expected fresh child-entry scope refusal")
            } catch let error as SPICEProfileParseFailure { #expect(error.diagnostic.severity == .error) }
            #expect(await missing.requests().first?.environment.parameters.isEmpty == true)
        }
    }

    @Test func resolverResourceErrorsAndLateCancellationPropagateWithoutLaterAcquisition() async throws {
        let resources = GrammarTestResources()
        let root = try source(".include first\n.include second\n", key: "root", occurrence: 0, resources)
        let environment = try empty(resources)
        let refused = FixtureResolver(resources: resources, sources: [:], behavior: .resourceFailure)
        do {
            _ = try await SPICEParser().parseProfile(document: root, configuration: configuration,
                environment: environment, resolver: refused, resources: resources)
            Issue.record("Expected resolver resource refusal")
        } catch let error as GrammarTestError { #expect(error == .hashLimit) }
        #expect(await refused.requests().count == 1)
        let diagnostic = FixtureResolver(resources: resources, sources: [:], behavior: .diagnosticFailure)
        do {
            _ = try await SPICEParser().parseProfile(document: root, configuration: configuration,
                environment: environment, resolver: diagnostic, resources: resources)
            Issue.record("Expected exact resolver diagnostic propagation")
        } catch let error as ParserDiagnostic { #expect(error.message == "Provider refused") }
        let nested = FixtureResolver(resources: resources, sources: ["first": ".include nested\n"], behavior: .nestedDiagnosticFailure)
        do {
            _ = try await SPICEParser().parseProfile(document: root, configuration: configuration,
                environment: environment, resolver: nested, resources: resources)
            Issue.record("Expected nested resolver diagnostic propagation")
        } catch let error as ParserDiagnostic { #expect(error.message == "Provider refused") }
        #expect(await nested.requests().count == 2)
        let late = FixtureResolver(resources: resources, sources: ["first": ".model m nmos\n"], behavior: .lateCancellation)
        do {
            _ = try await SPICEParser().parseProfile(document: root, configuration: configuration,
                environment: environment, resolver: late, resources: resources)
            Issue.record("Expected cancellation after resolution")
        } catch let error as GrammarTestError { #expect(error == .cancelled) }
        #expect(await late.requests().count == 1)
    }

    @Test func invalidOwnershipSectionAndRepeatedOccurrenceAreExplicitFailures() async throws {
        for behavior in [FixtureResolver.Behavior.unaccounted, .wrongSection, .repeatedOccurrence] {
            let resources = GrammarTestResources()
            let root = try source(".include child\n", key: "root", occurrence: 0, resources)
            let resolver = FixtureResolver(resources: resources, sources: ["child": ".model m nmos\n"], behavior: behavior)
            do {
                _ = try await SPICEParser().parseProfile(document: root, configuration: configuration,
                    environment: empty(resources), resolver: resolver, resources: resources)
                Issue.record("Expected checked child-context refusal")
            } catch let error as SPICEBoundedSourceError {
                #expect(error == (behavior == .unaccounted ? .unaccountedSource : .invalidSourceContext))
            }
        }
    }

    @Test func disabledResolutionUnresolvedConditionDepthAndStorageRefusePublication() async throws {
        let resources = GrammarTestResources()
        let environment = try empty(resources)
        let root = try source(".include child\n", key: "root", occurrence: 0, resources)
        let resolver = FixtureResolver(resources: resources, sources: ["child": ".model m nmos\n"])
        do {
            _ = try await SPICEParser().parseProfile(document: root, configuration: .default,
                environment: environment, resolver: resolver, resources: resources)
            Issue.record("Expected disabled-resolution refusal")
        } catch let error as SPICEBoundedSourceError {
            #expect(error == .unsupportedBudgetCapability("Disabled include resolution"))
        }
        do {
            _ = try await SPICEParser().parseProfile(document: root,
                configuration: ParserConfiguration(maxIncludeDepth: 0, resolveIncludes: true),
                environment: environment, resolver: resolver, resources: resources)
            Issue.record("Expected depth refusal")
        } catch let error as SPICEProfileParseFailure { #expect(error.diagnostic.message == "Maximum include depth exceeded") }
        #expect(await resolver.requests().isEmpty)
        let conditional = try source(".if missing\n.model unused nmos\n.endif\n", key: "root", occurrence: 0, resources)
        do {
            _ = try await SPICEParser().parseProfile(document: conditional, configuration: configuration,
                environment: environment, resolver: resolver, resources: resources)
            Issue.record("Expected unresolved-condition refusal")
        } catch let error as SPICEProfileParseFailure { #expect(error.diagnostic.severity == .error) }
        let capacity = GrammarTestResources(liveLimit: 0)
        do {
            _ = try await SPICEParser().parseProfile(document: root, configuration: configuration,
                environment: environment, resolver: resolver, resources: capacity)
            Issue.record("Expected storage refusal")
        } catch let error as GrammarTestError { #expect(error == .limit(.liveOwnedBytes)) }
    }

    @Test func finalResultCopiesKeepSourceAndActualDerivedStorageUntilLastCopy() async throws {
        let resources = GrammarTestResources()
        var root: SPICESourceDocument? = try source(".model exact nmos (version=4.8)\n", key: "root", occurrence: 0, resources)
        var environment: SPICEPreprocessingEnvironment? = try empty(resources)
        let resolver = FixtureResolver(resources: resources, sources: [:])
        var result: SPICEOwnedParseResult? = try await SPICEParser().parseProfile(document: #require(root),
            configuration: configuration, environment: #require(environment), resolver: resolver, resources: resources)
        let ordinary = try await SPICEParser().parse(document: #require(root), configuration: configuration,
            fileResolver: NullFileResolver())
        #expect(result?.netlist.models.first?.name == ordinary.netlist?.models.first?.name)
        #expect(result?.netlist.models.first?.type == ordinary.netlist?.models.first?.type)
        #expect(result?.netlist.models.first?.parameters == ordinary.netlist?.models.first?.parameters)
        root = nil; environment = nil
        let live = resources.used(.liveOwnedBytes)
        #expect(live > 0)
        #expect(resources.used(.temporaryBytes) == 0)
        var copy = result
        result = nil
        withExtendedLifetime(copy) { #expect(resources.used(.liveOwnedBytes) == live) }
        copy = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func cumulativeDependencyWorkStopsBeforeTheSecondResolverCall() async throws {
        let resources = GrammarTestResources(dependencyExpansionLimit: 1)
        let root = try source(".include child\n.include child\n", key: "root", occurrence: 0, resources)
        let resolver = FixtureResolver(resources: resources, sources: ["child": ".model m nmos\n"])
        do {
            _ = try await SPICEParser().parseProfile(document: root, configuration: configuration,
                environment: empty(resources), resolver: resolver, resources: resources)
            Issue.record("Expected cumulative dependency work refusal")
        } catch let error as GrammarTestError { #expect(error == .workLimit) }
        #expect(await resolver.requests().count == 1)
    }

    @Test func copiedSyntaxFailureRetainsOnlyItsSourceAndDiagnosticPayload() async throws {
        let resources = GrammarTestResources()
        var root: SPICESourceDocument? = try source(".model broken\n", key: "root", occurrence: 0, resources)
        var environment: SPICEPreprocessingEnvironment? = try empty(resources)
        let resolver = FixtureResolver(resources: resources, sources: [:])
        var failure: SPICEProfileParseFailure?
        do {
            _ = try await SPICEParser().parseProfile(document: #require(root), configuration: configuration,
                environment: #require(environment), resolver: resolver, resources: resources)
            Issue.record("Expected grammar failure")
        } catch let error as SPICEProfileParseFailure { failure = error }
        #expect(resources.sawReservation(.liveOwnedBytes,
            byteCount: UInt64(MemoryLayout<SPICEProfileParseFailure>.stride)))
        root = nil; environment = nil
        let live = resources.used(.liveOwnedBytes)
        #expect(live > 0)
        #expect(resources.used(.temporaryBytes) == 0)
        var copy = failure
        failure = nil
        withExtendedLifetime(copy) { #expect(resources.used(.liveOwnedBytes) == live) }
        copy = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    private func empty(_ resources: GrammarTestResources) throws -> SPICEPreprocessingEnvironment {
        try .empty(policyIdentity: "inspection-policy", configuration: configuration,
            resources: resources, maximumPageByteCount: 256)
    }
    private func source(_ text: String, key: String, occurrence: UInt64,
                        _ resources: GrammarTestResources) throws -> SPICESourceDocument {
        try SPICESourceDocument(accountedText: SPICEAccountedText.copy(text, resources: resources,
            maximumChunkByteCount: 256), sourceKey: key, occurrenceID: .init(occurrence), resolvedPath: key)
    }
}

private actor FixtureResolver: SPICEContextualFileResolver {
    enum Behavior: Sendable, Equatable { case normal, resourceFailure, diagnosticFailure, nestedDiagnosticFailure, lateCancellation, unaccounted, wrongSection, repeatedOccurrence }
    private let resources: GrammarTestResources
    private let sources: [String: String]
    private let behavior: Behavior
    private var observed: [SPICESourceDependencyRequest] = []
    private var next: UInt64 = 1
    init(resources: GrammarTestResources, sources: [String: String], behavior: Behavior = .normal) {
        self.resources = resources; self.sources = sources; self.behavior = behavior
    }
    func requests() -> [SPICESourceDependencyRequest] { observed }
    func resolve(_ request: SPICESourceDependencyRequest) async throws -> SPICESourceDocument {
        observed.append(request)
        if behavior == .resourceFailure { throw GrammarTestError.hashLimit }
        if behavior == .diagnosticFailure || (behavior == .nestedDiagnosticFailure && observed.count == 2) {
            throw ParserDiagnostic.error("Provider refused")
        }
        guard let original = sources[request.literalRoute] else { throw GrammarTestError.hashLimit }
        let text = behavior == .wrongSection ? ".lib wrong\n.model m nmos\n.endl wrong\n" : original
        if behavior == .unaccounted { return SPICESourceDocument(text: text, captureID: request.literalRoute) }
        let id = behavior == .repeatedOccurrence ? 0 : next
        next += 1
        let full = try SPICESourceDocument(accountedText: SPICEAccountedText.copy(text, resources: resources,
            maximumChunkByteCount: 256), sourceKey: request.literalRoute, occurrenceID: .init(id), resolvedPath: request.literalRoute)
        let selected = try full.selectingLibrarySection(behavior == .wrongSection ? "wrong" : request.requestedChildSection,
            resources: resources)
        if behavior == .lateCancellation { resources.setCancelled(true) }
        return selected
    }
}

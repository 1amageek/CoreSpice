import CircuiteFoundation
import CircuiteFoundationCrypto
import CoreSpiceIO
import Foundation
import Synchronization
import Testing

@Suite("Exact grammar-owned SPICE intake")
struct SPICEExactSourceIntakeTests {
    private func limits(_ overrides: [SPICESourceWorkKind: UInt64] = [:]) -> SPICESourceWorkLimits {
        var values = Dictionary(uniqueKeysWithValues: SPICESourceWorkKind.allCases.map { ($0, UInt64(1_000_000)) })
        values.merge(overrides) { _, new in new }
        return SPICESourceWorkLimits(limits: values)
    }

    private func binding(_ key: String, _ text: String) throws -> SPICEExactSourceBinding {
        let bytes = Array(text.utf8)
        let result = try SHA256ContentDigester().digest(using: .sha256,
            limits: ContentDigestSessionLimits(maximumChunkByteCount: UInt64(max(1, bytes.count)),
                maximumTotalByteCount: UInt64(max(1, bytes.count)), maximumUpdateCount: 1)) {
                    (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in
            try lease.update(bytes)
        }
        return SPICEExactSourceBinding(key: key, reference: try ArtifactReference(digest: result.digest,
            byteCount: UInt64(bytes.count), descriptor: ArtifactDescriptor(role: .input, kind: .netlist, format: .spice)))
    }

    private func request(_ bindings: [SPICEExactSourceBinding], edges: [SPICEExpectedDependency] = [],
                         section: String? = nil, parameters: [String: String] = [:], depth: Int = 32,
                         workLimits: SPICESourceWorkLimits? = nil) -> SPICEExactLoadRequest {
        SPICEExactLoadRequest(rootKey: "root", selectedSection: section, initialParameters: parameters,
            expectedSources: bindings, expectedDependencies: edges,
            configuration: ParserConfiguration(maxIncludeDepth: depth, resolveIncludes: true),
            capturePolicy: .hostDefault, workLimits: workLimits ?? limits())
    }

    @Test func repeatedNestedGrammarRetainsExactSourcesAndOrigins() async throws {
        let root = "graph\n.param choice=1\n.if choice\n.include 'cells.inc'\n.endif\n.include \"cells.inc\"\n.end\n"
        let cell = ".lib 'models.lib' tt\n"
        let model = "* library\n.lib ff\n.model other R r=200\n.endl\n.lib tt\n.model sheet R r=100\n+ tc1=0.001\n.endl\n"
        let sources = try [binding("root", root), binding("cell", cell), binding("models", model)]
        let context = ["choice": "1.0"]
        let edges = [
            SPICEExpectedDependency(parentKey: "root", childKey: "cell", kind: .include, path: "cells.inc", line: 4, preprocessingContext: context),
            SPICEExpectedDependency(parentKey: "cell", childKey: "models", kind: .externalLibrary, path: "models.lib", selectedSection: "tt", line: 1, preprocessingContext: context),
            SPICEExpectedDependency(parentKey: "root", childKey: "cell", kind: .include, path: "cells.inc", line: 6, preprocessingContext: context),
            SPICEExpectedDependency(parentKey: "cell", childKey: "models", kind: .externalLibrary, path: "models.lib", selectedSection: "tt", line: 1, preprocessingContext: context)
        ]
        let provider = ExactTestProvider(bytes: ["root": Data(root.utf8), "cell": Data(cell.utf8), "models": Data(model.utf8)])
        let loader: any SPICEDeckSourceLoading = SPICEExactDeckLoader()
        let loaded = try await loader.load(request: request(sources, edges: edges), provider: provider,
            work: try SPICEBoundedSourceWork(limits: limits()))
        #expect(loaded.inputReferences == sources.map(\.reference))
        #expect(await provider.calls == ["root", "cell", "models"])
        #expect(loaded.captures.count == 3)
        #expect(loaded.captures.last?.bytes == Data(model.utf8))
        #expect(loaded.netlist.models.map(\.name) == ["sheet", "sheet"])
        #expect(loaded.netlist.models.allSatisfy { $0.location?.line == 6 && $0.origin?.captureID == "models" })
        #expect(loaded.dependencyEvents.map(\.ordinal) == [0, 1, 2, 3])
        #expect(loaded.sourceWorkConsumption[.dependencyExpansions] == 4)
        #expect(loaded.netlist.preprocessingEvents.first?.active == true)
    }

    @Test func rootLocalSectionAndInactiveConditionalAreNotDependencies() async throws {
        let root = "* library\n.lib ff\n.include 'not-admitted.inc'\n.endl\n.lib tt\n.if 0\n.include 'inactive.inc'\n.endif\n.model sheet R r=100\n.endl\n"
        let source = try binding("root", root)
        let loaded = try await SPICEExactDeckLoader().load(request: request([source], section: "tt"),
            provider: ExactTestProvider(bytes: ["root": Data(root.utf8)]),
            work: try SPICEBoundedSourceWork(limits: limits()))
        #expect(loaded.dependencyEvents.isEmpty)
        #expect(loaded.netlist.models.first?.location?.line == 9)
        #expect(loaded.netlist.preprocessingEvents.first?.active == false)
        #expect(loaded.captures.first?.bytes == Data(root.utf8))
    }

    @Test func changedBytesAndFullDescriptorDriftFail() async throws {
        let root = "title\n.end\n"
        let source = try binding("root", root)
        await #expect(throws: SPICEExactSourceError.sourceDrift("root")) {
            try await SPICEExactDeckLoader().load(request: request([source]),
                provider: ExactTestProvider(bytes: ["root": Data("other\n.end\n".utf8)]),
                work: SPICEBoundedSourceWork(limits: limits()))
        }
        let other = SPICEExactSourceBinding(key: "root", reference: ArtifactReference(id: source.reference.id,
            descriptor: ArtifactDescriptor(role: .output, kind: .model, format: .spice)))
        await #expect(throws: SPICEExactSourceError.sourceDrift("root")) {
            try await SPICEExactDeckLoader().load(request: request([source]),
                provider: ExactTestProvider(bytes: ["root": Data(root.utf8)], returnedBinding: other),
                work: SPICEBoundedSourceWork(limits: limits()))
        }
    }

    @Test func undeclaredMissingUnusedAndGraphContextFail() async throws {
        let root = "title\n.include 'child.inc'\n.end\n"
        let child = ".model sheet R r=100\n"
        let sources = try [binding("root", root), binding("child", child)]
        let edge = SPICEExpectedDependency(parentKey: "root", childKey: "child", kind: .include, path: "child.inc", line: 2)
        let provider = ExactTestProvider(bytes: ["root": Data(root.utf8), "child": Data(child.utf8)])
        await #expect(throws: SPICEExactSourceError.undeclaredDependency(parent: "root", path: "child.inc")) {
            try await SPICEExactDeckLoader().load(request: request(sources), provider: provider,
                work: SPICEBoundedSourceWork(limits: limits()))
        }
        await #expect(throws: ExactTestError.missing("child")) {
            try await SPICEExactDeckLoader().load(request: request(sources, edges: [edge]),
                provider: ExactTestProvider(bytes: ["root": Data(root.utf8)]), work: SPICEBoundedSourceWork(limits: limits()))
        }
        let wrong = SPICEExpectedDependency(parentKey: "root", childKey: "child", kind: .include,
            path: "child.inc", line: 3, preprocessingContext: ["wrong": "1"])
        await #expect(throws: SPICEExactSourceError.graphMismatch) {
            try await SPICEExactDeckLoader().load(request: request(sources, edges: [wrong]), provider: provider,
                work: SPICEBoundedSourceWork(limits: limits()))
        }
        let empty = "title\n.end\n"
        await #expect(throws: SPICEExactSourceError.unusedSource("child")) {
            try await SPICEExactDeckLoader().load(request: request([binding("root", empty), sources[1]]),
                provider: ExactTestProvider(bytes: ["root": Data(empty.utf8), "child": Data(child.utf8)]),
                work: SPICEBoundedSourceWork(limits: limits()))
        }
    }

    @Test func sectionUnknownConditionalAndUnsupportedGrammarFail() async throws {
        for sourceText in ["title\n.if unknown\nR1 a 0 1k\n.endif\n.end\n", "title\n.unsupported x\n.end\n"] {
            let source = try binding("root", sourceText)
            await #expect(throws: ParserDiagnostic.self) {
                try await SPICEExactDeckLoader().load(request: request([source]),
                    provider: ExactTestProvider(bytes: ["root": Data(sourceText.utf8)]),
                    work: SPICEBoundedSourceWork(limits: limits()))
            }
        }
        let root = "* lib\n.lib tt\n.model sheet R r=100\n.endl\n"
        await #expect(throws: FileResolverError.self) {
            try await SPICEExactDeckLoader().load(request: request([binding("root", root)], section: "missing"),
                provider: ExactTestProvider(bytes: ["root": Data(root.utf8)]), work: SPICEBoundedSourceWork(limits: limits()))
        }
    }

    @Test func expansionDepthAndPreallocationWorkLimitsFail() async throws {
        let root = "title\n.include 'child.inc'\n.include 'child.inc'\n.end\n"
        let child = ".model sheet R r=100\n"
        let sources = try [binding("root", root), binding("child", child)]
        let edges = [2, 3].map { SPICEExpectedDependency(parentKey: "root", childKey: "child", kind: .include, path: "child.inc", line: $0) }
        let provider = ExactTestProvider(bytes: ["root": Data(root.utf8), "child": Data(child.utf8)])
        await #expect(throws: SPICEExactSourceError.workLimit(.dependencyExpansions)) {
            try await SPICEExactDeckLoader().load(request: request(sources, edges: edges, workLimits: limits([.dependencyExpansions: 1])),
                provider: provider, work: SPICEBoundedSourceWork(limits: limits()))
        }
        await #expect(throws: SPICEExactSourceError.workLimit(.tokens)) {
            try await SPICEExactDeckLoader().load(request: request(sources, edges: edges, workLimits: limits([.tokens: 1])),
                provider: provider, work: SPICEBoundedSourceWork(limits: limits()))
        }
        let recursive = ".include 'child.inc'\n"
        let recursiveSources = try [sources[0], binding("child", recursive)]
        let recursiveEdges = [edges[0], SPICEExpectedDependency(parentKey: "child", childKey: "child", kind: .include, path: "child.inc", line: 1)]
        await #expect(throws: ParserDiagnostic.self) {
            try await SPICEExactDeckLoader().load(request: request(recursiveSources, edges: recursiveEdges, depth: 1),
                provider: ExactTestProvider(bytes: ["root": Data(root.utf8), "child": Data(recursive.utf8)]),
                work: SPICEBoundedSourceWork(limits: limits()))
        }
    }

    @Test func concurrentWorkAdmissionCannotOversubscribeItsCeiling() async throws {
        let work = try SPICEBoundedSourceWork(limits: limits([.tokens: 16]))
        let admitted = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    do { try work.charge(.tokens, units: 1); return true }
                    catch SPICEExactSourceError.workLimit(.tokens) { return false }
                }
            }
            var count = 0
            for try await accepted in group where accepted { count += 1 }
            return count
        }
        #expect(admitted == 16)
        #expect(work.consumption[.tokens] == 16)
    }

    @Test func nestedExpressionAndASTRetentionUseTheSameBudget() throws {
        let addition = Array(repeating: "1", count: 100).joined(separator: "+")
        #expect(throws: SPICEExactSourceError.workLimit(.tokens)) {
            try SPICEExpressionParser().parse("'" + addition + "'",
                work: SPICEBoundedSourceWork(limits: limits([.tokens: 3])))
        }
        #expect(throws: SPICEExactSourceError.workLimit(.retainedElements)) {
            try SPICEExpressionParser().parse(addition,
                work: SPICEBoundedSourceWork(limits: limits([.retainedElements: 1])))
        }
    }

    @Test func subcircuitDefaultLexingCannotBypassWork() async throws {
        let source = "title\n.subckt cell p q params:a=1 b=2\n.ends cell\n.end\n"
        await #expect(throws: SPICEExactSourceError.workLimit(.lexicalBytes)) {
            try await SPICEParser().parseChecked(document: SPICESourceDocument(text: source),
                configuration: ParserConfiguration(resolveIncludes: true), fileResolver: NullFileResolver(),
                work: SPICEBoundedSourceWork(limits: limits([.lexicalBytes: UInt64(source.utf8.count)])))
        }
    }

    @Test func bareExternalLibraryIsNotAnUnrelatedLocalSection() async throws {
        let resolver = BareLibraryResolver()
        let result = await SPICEParser().parse(document: SPICESourceDocument(text:
            "title\n.lib models.lib\n.lib tt\n.model local R r=2\n.endl\n.end\n"),
            configuration: ParserConfiguration(resolveIncludes: true), fileResolver: resolver)
        let netlist = try result.get()
        #expect(netlist.models.map(\.name) == ["external", "local"])
        #expect(await resolver.calls == ["models.lib"])
    }

    @Test func cancellationStopsInsideLongTokenAndConditionalEvaluation() async throws {
        var lexer = SPICELexer(source: String(repeating: "x", count: 8192))
        #expect(throws: CancellationError.self) {
            try lexer.tokenizeChecked(work: CancellationProbe(after: 2))
        }
        let source = "title\n.model " + String(repeating: "x", count: 8192) + " R r=100\n.end\n"
        let root = try binding("root", source)
        await #expect(throws: CancellationError.self) {
            try await SPICEExactDeckLoader().load(request: request([root]),
                provider: ExactTestProvider(bytes: ["root": Data(source.utf8)]), work: CancellationProbe(after: 20))
        }
        let conditional = "title\n.param a=1\n.if a+a+a+a\nR1 a 0 1k\n.endif\n.end\n"
        await #expect(throws: SPICEExactSourceError.workLimit(.conditionalEvaluations)) {
            try await SPICEExactDeckLoader().load(request: request([binding("root", conditional)],
                workLimits: limits([.conditionalEvaluations: 1])),
                provider: ExactTestProvider(bytes: ["root": Data(conditional.utf8)]),
                work: SPICEBoundedSourceWork(limits: limits()))
        }
    }
    @Test func exactSourceIntakeRetainsUnusedUnsupportedDefinitions() async throws {
        let text = "exact unused\nV1 out 0 1\nR1 out 0 1k\n.model cm C level=2 cap={missing}\n.subckt cell a\n.model jm NJF beta=1m vto=-1\nJ1 a 0 0 jm unsupported={missing}\n.ends\n.op\n.end\n"
        let source = try binding("root", text)
        let loaded = try await SPICEExactDeckLoader().load(request: request([source]),
            provider: ExactTestProvider(bytes: ["root": Data(text.utf8)]),
            work: SPICEBoundedSourceWork(limits: limits()))
        #expect(loaded.coverage.hasBlockedItems)
        #expect(loaded.coverage.items.contains { $0.name == "model:cm" && $0.status == .blocked })
        #expect(loaded.coverage.items.contains { $0.name == "subckt:cell/component:j1" && $0.status == .blocked })
        #expect(loaded.inputReferences == [source.reference])
        #expect(loaded.captures.first?.bytes == Data(text.utf8))
        #expect(try IOTestFrontend.lower(loaded.netlist).instances.count == 2)
        let selected = text.replacingOccurrences(of: ".op\n", with: "X1 out cell\n.op\n")
        let selectedBinding = try binding("root", selected)
        let selectedDeck = try await SPICEExactDeckLoader().load(request: request([selectedBinding]),
            provider: ExactTestProvider(bytes: ["root": Data(selected.utf8)]),
            work: SPICEBoundedSourceWork(limits: limits()))
        do {
            _ = try IOTestFrontend.lower(selectedDeck.netlist)
            Issue.record("Selected unsupported field bypassed actual lowering")
        } catch let error as LoweringError {
            guard case .invalidComponent(let name, let reason) = error else { throw error }
            #expect(name == "x1.j1")
            #expect(reason.contains("unsupported"))
        }
    }

    @Test func exactModelBracedQuotesRetainCapturedSourceAndFlatPrecedence() async throws {
        let text = "exact model quote elision\n.param a=1k b=2k\n.model sheet R rsh={2*\"a+b\"}\nR1 out 0 sheet l=1u w=1u\n.end\n"
        let source = try binding("root", text)
        let loaded = try await SPICEExactDeckLoader().load(request: request([source]),
            provider: ExactTestProvider(bytes: ["root": Data(text.utf8)]),
            work: SPICEBoundedSourceWork(limits: limits()))
        #expect(loaded.inputReferences == [source.reference])
        #expect(loaded.captures.first?.bytes == Data(text.utf8))
        let ir = try IOTestFrontend.lower(loaded.netlist)
        guard case .real(let value) = try #require(ir.instances.first?.model?.parameters["rsh"]) else {
            Issue.record("Missing actual model coefficient"); return
        }
        #expect(value == 4000)
    }

    @Test func exactRootIntentRefusesBeforeSelectedNumerics() async throws {
        let text = "exact blocked\n.model cm C cap=1n\n.alter R1 resistance=2k\n.end\n"
        let source = try binding("root", text)
        do {
            _ = try await SPICEExactDeckLoader().load(request: request([source]),
                provider: ExactTestProvider(bytes: ["root": Data(text.utf8)]),
                work: SPICEBoundedSourceWork(limits: limits()))
            Issue.record("Exact root control bypassed intake")
        } catch let error as SPICEDeckLoadError {
            guard case .blockedExecutionIntent(let items) = error else { throw error }
            #expect(items.count == 1)
            #expect(items.first?.name.hasPrefix("alter:") == true)
        }
    }

}

private enum ExactTestError: Error, Equatable { case missing(String) }

private actor ExactTestProvider: SPICEExactSourceProviding {
    let bytes: [String: Data]
    let returnedBinding: SPICEExactSourceBinding?
    var calls: [String] = []
    init(bytes: [String: Data], returnedBinding: SPICEExactSourceBinding? = nil) {
        self.bytes = bytes
        self.returnedBinding = returnedBinding
    }
    func source(for binding: SPICEExactSourceBinding, work: any SPICESourceWorkAccounting,
                maximumPageByteCount: UInt64) throws -> SPICECheckedSource {
        calls.append(binding.key)
        guard let bytes = bytes[binding.key] else { throw ExactTestError.missing(binding.key) }
        return try SPICECheckedSource.admit(binding: returnedBinding ?? binding, bytes: bytes,
            work: work, maximumPageByteCount: maximumPageByteCount)
    }
}

private final class CancellationProbe: SPICESourceWorkAccounting {
    let remaining: Mutex<Int>
    init(after checks: Int) { remaining = Mutex(checks) }
    func charge(_ kind: SPICESourceWorkKind, units: UInt64) throws {}
    func checkCancellation() throws {
        let exhausted = remaining.withLock { state in state -= 1; return state <= 0 }
        if exhausted { throw CancellationError() }
    }
}

private actor BareLibraryResolver: FileResolver {
    var calls: [String] = []
    func resolveLibrary(path: String, section: String?, relativeTo: String?) throws -> SPICESourceDocument {
        calls.append(path)
        return SPICESourceDocument(text: ".model external R r=1\n", resolvedPath: "external", captureID: "external")
    }
    func resolveInclude(path: String, relativeTo: String?) throws -> SPICESourceDocument {
        throw FileResolverError.fileNotFound(path: path)
    }
    func readFile(at path: String) throws -> SPICESourceDocument { throw FileResolverError.fileNotFound(path: path) }
}

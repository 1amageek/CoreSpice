import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

@Suite("Checked concrete MOS invocation environments")
struct MOSInvocationTests {
    @Test func orderedDefaultsActualWinnersAndNewSymbolsPreserveOccurrences() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil)
        let child = try builder.addScope(parent: root)
        let a = try builder.intern("a"), extra = try builder.intern("extra")
        let one = try builder.addProgram(.literal(1)), two = try builder.addProgram(.literal(2))
        let first = try builder.addBinding(symbol: a, scope: child, program: one)
        let last = try builder.addBinding(symbol: a, scope: child, program: two)
        let snapshot = try builder.finish()
        let actualSource = source("actual.sp")
        let graph = try MOSInvocationGraph(snapshot: snapshot, invocations: [
            try invocation(1, root, limits: limits),
            try invocation(2, child, caller: 1, actuals: [
                try MOSInvocationActual(symbol: a, program: one, source: actualSource, limits: limits),
                try MOSInvocationActual(symbol: extra, program: two, limits: limits)
            ], limits: limits),
            try invocation(3, child, caller: 1, limits: limits)
        ], limits: limits)
        let localOverride = try graph.localBinding(a, in: 2)
        let overridden = try #require(localOverride)
        #expect(overridden.program == one && overridden.sourceBindingID == nil)
        #expect(overridden.source == actualSource && overridden.selfReferenceCallerInvocationID == 1)
        #expect(try graph.localBinding(extra, in: 2)?.program == two)
        #expect(try graph.localBinding(a, in: 3)?.sourceBindingID == last)
        #expect(try graph.localBinding(a, in: 3)?.selfReferenceCallerInvocationID == nil)
        #expect(try snapshot.scope(child).parameterBindings == [first, last])
        #expect(snapshot.bindings.count == 2 && graph.finalBindings.count == 3)
        #expect(graph.snapshot.sameStorage(as: snapshot))
        #expect(graph.retainedBytes <= graph.peakOwnedBufferBytes)
    }

    @Test func numericCallerVisibilityDoesNotGrantLexicalModelFunctionVisibility() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil)
        let aScope = try builder.addScope(parent: root), bScope = try builder.addScope(parent: root)
        let p = try builder.intern("p"), g = try builder.intern("g")
        let value = try builder.addProgram(.literal(3))
        _ = try builder.addBinding(symbol: p, scope: aScope, program: value)
        _ = try builder.addBinding(symbol: g, scope: root, program: value)
        let graph = try MOSInvocationGraph(snapshot: builder.finish(), invocations: [
            try invocation(1, root, limits: limits),
            try invocation(2, aScope, caller: 1, limits: limits),
            try invocation(3, bScope, caller: 2, limits: limits)
        ], limits: limits)
        #expect(try graph.numericBinding(p, in: 3)?.ownerInvocation == 2)
        #expect(try graph.numericBinding(g, in: 3)?.ownerInvocation == 1)
        #expect(try graph.localBinding(p, in: 3) == nil)
        #expect(try graph.lexicalOwner(of: root, from: 3) == 1)
        #expect(throws: MOSResolutionFailure.invalidScope) { try graph.lexicalOwner(of: aScope, from: 3) }
    }

    @Test func repeatedAndNestedActualSelfReferencesKeepExactCallerIdentity() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil), parent = try builder.addScope(parent: root)
        let child = try builder.addScope(parent: root), a = try builder.intern("a")
        let selfProgram = try builder.addProgram(.reference(a))
        let actual = try MOSInvocationActual(symbol: a, program: selfProgram, limits: limits)
        let graph = try MOSInvocationGraph(snapshot: builder.finish(), invocations: [
            try invocation(1, root, limits: limits),
            try invocation(2, parent, caller: 1, limits: limits),
            try invocation(3, parent, caller: 1, limits: limits),
            try invocation(4, child, caller: 2, actuals: [actual], limits: limits),
            try invocation(5, child, caller: 3, actuals: [actual], limits: limits)
        ], limits: limits)
        #expect(try graph.localBinding(a, in: 4)?.selfReferenceCallerInvocationID == 2)
        #expect(try graph.localBinding(a, in: 5)?.selfReferenceCallerInvocationID == 3)
        #expect(graph.maximumDepth == 3)
    }

    @Test func duplicateActualNamesAndInvalidAncestryRefusePublication() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil), a = try builder.addScope(parent: root)
        let nested = try builder.addScope(parent: a), symbol = try builder.intern("p")
        let program = try builder.addProgram(.literal(1)), snapshot = try builder.finish()
        let actual = try MOSInvocationActual(symbol: symbol, program: program, limits: limits)
        #expect(throws: MOSResolutionFailure.duplicateParameter(symbol)) {
            try invocation(2, a, caller: 1, actuals: [actual, actual], limits: limits)
        }
        let global = try invocation(1, root, limits: limits)
        #expect(throws: MOSResolutionFailure.duplicateInvocation(1)) {
            try MOSInvocationGraph(snapshot: snapshot, invocations: [global, global], limits: limits)
        }
        #expect(throws: MOSResolutionFailure.invalidInvocation(2)) {
            try MOSInvocationGraph(snapshot: snapshot, invocations: [
                try invocation(2, a, caller: 1, limits: limits), global
            ], limits: limits)
        }
        #expect(throws: MOSResolutionFailure.invalidInvocation(2)) {
            try MOSInvocationGraph(snapshot: snapshot, invocations: [global,
                try invocation(2, nested, caller: 1, limits: limits)
            ], limits: limits)
        }
        #expect(throws: MOSResolutionFailure.invalidInvocation(99)) {
            let graph = try MOSInvocationGraph(snapshot: snapshot, invocations: [global], limits: limits)
            return try graph.invocation(99)
        }
    }

    @Test func graphWorkCapacityDepthAndCancellationAreAdmittedBeforePublication() throws {
        let admitted = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: admitted)
        let root = try builder.addScope(parent: nil), child = try builder.addScope(parent: root)
        let symbol = try builder.intern("p"), program = try builder.addProgram(.literal(1))
        _ = try builder.addBinding(symbol: symbol, scope: child, program: program)
        let snapshot = try builder.finish()
        let input = [try invocation(1, root, limits: admitted), try invocation(2, child, caller: 1, limits: admitted)]
        #expect(throws: MOSResolutionFailure.limitExceeded(.invocations)) {
            try MOSInvocationGraph(snapshot: snapshot, invocations: input, limits: self.limits(invocations: 1))
        }
        #expect(throws: MOSResolutionFailure.limitExceeded(.scopeDepth)) {
            try MOSInvocationGraph(snapshot: snapshot, invocations: input, limits: self.limits(depth: 1))
        }
        #expect(throws: MOSResolutionFailure.limitExceeded(.evaluationSteps)) {
            try MOSInvocationGraph(snapshot: snapshot, invocations: input, limits: self.limits(steps: 1))
        }
        #expect(throws: MOSResolutionFailure.limitExceeded(.retainedBytes)) {
            try MOSInvocationGraph(snapshot: snapshot, invocations: input, limits: self.limits(bytes: 1))
        }
        #expect(throws: MOSResolutionFailure.cancelled) {
            try MOSInvocationGraph(snapshot: snapshot, invocations: input, limits: admitted,
                control: CancelledMOSInvocationConstruction())
        }
        let huge = source(String(repeating: "p", count: 4096))
        let sourced = try invocation(3, child, caller: 1, source: huge, limits: admitted)
        #expect(throws: MOSResolutionFailure.limitExceeded(.retainedBytes)) {
            try MOSInvocationGraph(snapshot: snapshot, invocations: [input[0], sourced], limits: self.limits(bytes: 2048))
        }
    }

    @Test func snapshotIdentityCannotBeReboundByEqualNumericIDs() throws {
        let limits = try limits()
        var first = MOSDeclarationSnapshotBuilder(limits: limits), second = MOSDeclarationSnapshotBuilder(limits: limits)
        _ = try first.addScope(parent: nil); _ = try second.addScope(parent: nil)
        let a = try first.finish(), b = try second.finish()
        #expect(a.scopes[0].id == b.scopes[0].id)
        #expect(a.identitySpace.sameStorage(as: a.identitySpace))
        #expect(!a.identitySpace.sameStorage(as: b.identitySpace))
    }

    private func invocation(_ id: UInt64, _ scope: MOSScopeID, caller: UInt64? = nil,
                            actuals: [MOSInvocationActual] = [], source: MOSSourceOccurrence? = nil,
                            limits: MOSResolutionLimits) throws(MOSResolutionFailure) -> MOSScopeInvocation {
        try MOSScopeInvocation(id: id, scope: scope, callerInvocationID: caller,
            actuals: actuals, source: source, limits: limits)
    }
    private func source(_ path: String) -> MOSSourceOccurrence {
        MOSSourceOccurrence(captureID: nil, occurrenceID: nil, path: path, line: 1,
            column: 1, statementByteOffset: nil, statementOrdinal: nil)
    }
    private func limits(invocations: Int = 64, depth: Int = 16, steps: UInt64 = 100_000,
                        bytes: UInt64 = 1_000_000) throws(MOSResolutionFailure) -> MOSResolutionLimits {
        try MOSResolutionLimits(maximumRetainedBytes: bytes, maximumDiagnosticBytes: 2048,
            maximumScopeDepth: depth, maximumSymbols: 64, maximumScopes: 16,
            maximumInvocations: invocations, maximumInvocationBindings: 256,
            maximumDeclarations: 64, maximumPrograms: 64, maximumBindings: 64,
            maximumFunctions: 16, maximumFunctionDepth: 16, maximumExpressionNodes: 64,
            maximumExpressionDepth: 64, maximumCandidates: 64, maximumCacheEntries: 64,
            maximumEvaluationSteps: steps)
    }
}

private struct CancelledMOSInvocationConstruction: MOSResolutionControlling {
    func checkCancellation() throws(MOSResolutionFailure) { throw .cancelled }
    func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) { throw .cancelled }
}

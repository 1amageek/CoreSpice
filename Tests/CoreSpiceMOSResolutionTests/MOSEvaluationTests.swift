import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

@Suite("Shared bounded MOS numerical evaluation")
struct MOSEvaluationTests {
    @Test func signedPowerPreservesNegativeBaseSign() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil), signed = try builder.intern("pwrs"), positive = try builder.intern("pwr")
        let signedProgram = try builder.addProgram(.function(signed, arguments: [.literal(-2), .literal(2)]))
        let positiveProgram = try builder.addProgram(.function(positive, arguments: [.literal(-2), .literal(2)]))
        let snapshot = try builder.finish(), graph = try graph(snapshot, [(1, root, nil, [])], limits)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        #expect(try evaluateMOSProgram(signedProgram, invocation: 1, lexicalScope: root, from: snapshot, session: &session) == -4)
        #expect(try evaluateMOSProgram(positiveProgram, invocation: 1, lexicalScope: root, from: snapshot, session: &session) == 4)
        #expect(session.randomDraws == 0)
    }

    @Test func bindingMemoSharesRandomButProgramSlotsAndInvocationsDoNot() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil), child = try builder.addScope(parent: root)
        let p = try builder.intern("p"), rand = try builder.intern("rand")
        let random = try builder.addProgram(.function(rand, arguments: []))
        _ = try builder.addBinding(symbol: p, scope: child, program: random)
        let snapshot = try builder.finish()
        let graph = try graph(snapshot, [(1, root, nil, []), (2, child, 1, []), (3, child, 1, [])], limits)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 0, limits: limits)
        let first = try evaluateMOSBinding(p, invocation: 2, from: snapshot, session: &session)
        let repeated = try evaluateMOSBinding(p, invocation: 2, from: snapshot, session: &session)
        let second = try evaluateMOSBinding(p, invocation: 3, from: snapshot, session: &session)
        #expect(first == repeated && first != second)
        #expect(first == 0.052790873358508184)
        #expect(session.randomDraws == 2)
        let direct = try evaluateMOSProgram(random, invocation: 2, lexicalScope: child, from: snapshot, session: &session)
        let another = try evaluateMOSProgram(random, invocation: 2, lexicalScope: child, from: snapshot, session: &session)
        #expect(direct != another && session.randomDraws == 4)
        #expect(session.retainedBytes <= session.peakOwnedBufferBytes)
        let provenance = session.finishProvenance()
        #expect(provenance.seed == 0 && provenance.randomDraws == 4)
        #expect(provenance.randomGeneratorVersion == "CoreSpice.XorShift64Star.v1")
        #expect(provenance.evaluatorVersion == "CoreSpice.MOSEvaluator.v2.temperature-freeze")
        #expect(provenance.rootVisits == [.binding(p, invocation: 2), .binding(p, invocation: 2),
            .binding(p, invocation: 3), .program(random, invocation: 2, lexicalScope: child),
            .program(random, invocation: 2, lexicalScope: child)])
    }

    @Test func callerActualSelfReferenceAndOtherSymbolsUseFinalChildEnvironment() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil), child = try builder.addScope(parent: root)
        let a = try builder.intern("a"), b = try builder.intern("b")
        let two = try builder.addProgram(.literal(2)), ten = try builder.addProgram(.literal(10))
        let actual = try builder.addProgram(.binary(.add, .reference(a), .reference(b)))
        _ = try builder.addBinding(symbol: a, scope: root, program: two)
        _ = try builder.addBinding(symbol: b, scope: child, program: ten)
        let snapshot = try builder.finish()
        let actualBinding = try MOSInvocationActual(symbol: a, program: actual, limits: limits)
        let graph = try graph(snapshot, [(1, root, nil, []), (2, child, 1, [actualBinding])], limits)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        #expect(try evaluateMOSBinding(a, invocation: 2, from: snapshot, session: &session) == 12)
    }

    @Test func rootOverridesShareSnapshotAndReevaluateDependentBindingsPerGraph() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil), a = try builder.intern("a"), dependent = try builder.intern("dependent")
        let one = try builder.addProgram(.literal(1))
        let twice = try builder.addProgram(.binary(.multiply, .reference(a), .literal(2)))
        _ = try builder.addBinding(symbol: a, scope: root, program: one)
        _ = try builder.addBinding(symbol: dependent, scope: root, program: twice)
        let snapshot = try builder.finish()
        let actual = try MOSInvocationActual(symbol: a, constant: 5, limits: limits)
        let original = try graph(snapshot, [(1, root, nil, [])], limits)
        let overridden = try graph(snapshot, [(1, root, nil, [actual])], limits)
        #expect(original.snapshot.sameStorage(as: overridden.snapshot))
        #expect(try overridden.localBinding(a, in: 1)?.selfReferenceCallerInvocationID == nil)
        var originalSession = try MOSEvaluationSession(snapshot: snapshot, graph: original, seed: 1, limits: limits)
        var overrideSession = try MOSEvaluationSession(snapshot: snapshot, graph: overridden, seed: 1, limits: limits)
        #expect(try evaluateMOSBinding(dependent, invocation: 1, from: snapshot, session: &originalSession) == 2)
        #expect(try evaluateMOSBinding(dependent, invocation: 1, from: snapshot, session: &overrideSession) == 10)
    }

    @Test func functionFormalsAreClearedAtNamedBindingsAndFreeNumbersUseCallsite() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil), child = try builder.addScope(parent: root)
        let p = try builder.intern("p"), bound = try builder.intern("bound"), f = try builder.intern("f")
        let rootValue = try builder.addProgram(.literal(3)), childValue = try builder.addProgram(.literal(7))
        let boundExpression = try builder.addProgram(.reference(p))
        let body = try builder.addProgram(.binary(.add, .reference(p), .reference(bound)))
        let call = try builder.addProgram(.function(f, arguments: [.literal(100)]))
        _ = try builder.addBinding(symbol: p, scope: root, program: rootValue)
        _ = try builder.addBinding(symbol: p, scope: child, program: childValue)
        _ = try builder.addBinding(symbol: bound, scope: root, program: boundExpression)
        _ = try builder.addFunction(symbol: f, scope: root, parameters: [p], program: body)
        let snapshot = try builder.finish(), graph = try graph(snapshot, [(1, root, nil, []), (2, child, 1, [])], limits)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        #expect(try evaluateMOSProgram(call, invocation: 2, lexicalScope: child, from: snapshot, session: &session) == 103)
    }

    @Test func nestedFunctionNamesAreLexicalWhileFreeNumericNamesUseCallerAncestry() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil), aScope = try builder.addScope(parent: root), bScope = try builder.addScope(parent: root)
        let f = try builder.intern("f"), g = try builder.intern("g"), p = try builder.intern("p")
        let rootG = try builder.addProgram(.literal(2)), callerG = try builder.addProgram(.literal(100))
        let callerP = try builder.addProgram(.literal(8))
        let body = try builder.addProgram(.binary(.add, .function(g, arguments: []), .reference(p)))
        let call = try builder.addProgram(.function(f, arguments: []))
        _ = try builder.addFunction(symbol: g, scope: root, parameters: [], program: rootG)
        _ = try builder.addFunction(symbol: g, scope: aScope, parameters: [], program: callerG)
        _ = try builder.addFunction(symbol: f, scope: root, parameters: [], program: body)
        _ = try builder.addBinding(symbol: p, scope: aScope, program: callerP)
        let snapshot = try builder.finish()
        let graph = try graph(snapshot, [(1, root, nil, []), (2, aScope, 1, []), (3, bScope, 2, [])], limits)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        #expect(try evaluateMOSProgram(call, invocation: 3, lexicalScope: bScope, from: snapshot, session: &session) == 10)
    }

    @Test func eagerUnusedArgumentsAndLazyBranchesPreserveDrawOrder() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil), f = try builder.intern("f"), x = try builder.intern("x")
        let rand = try builder.intern("rand"), missing = try builder.intern("missing")
        let body = try builder.addProgram(.literal(4))
        _ = try builder.addFunction(symbol: f, scope: root, parameters: [x], program: body)
        let random = MOSExpression.function(rand, arguments: [])
        let eager = try builder.addProgram(.function(f, arguments: [random]))
        let lazy = try builder.addProgram(.conditional(condition: .binary(.or, .literal(1), .reference(missing)),
            then: .binary(.and, .literal(0), random), else: .reference(missing)))
        let difference = try builder.addProgram(.binary(.subtract, random, random))
        let snapshot = try builder.finish(), graph = try graph(snapshot, [(1, root, nil, [])], limits)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 0, limits: limits)
        #expect(try evaluateMOSProgram(eager, invocation: 1, lexicalScope: root, from: snapshot, session: &session) == 4)
        #expect(session.randomDraws == 1)
        #expect(try evaluateMOSProgram(lazy, invocation: 1, lexicalScope: root, from: snapshot, session: &session) == 0)
        #expect(session.randomDraws == 1)
        let value = try evaluateMOSProgram(difference, invocation: 1, lexicalScope: root, from: snapshot, session: &session)
        #expect(value == 0.33112028100185353 - 0.6573173557412489)
        #expect(session.randomDraws == 3)
    }

    @Test func cyclesAndFailureAfterRandomPoisonWithoutRetryOrCapacityGrowth() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil), a = try builder.intern("a"), rand = try builder.intern("rand")
        let cycle = try builder.addProgram(.reference(a))
        let failing = try builder.addProgram(.binary(.divide, .function(rand, arguments: []), .literal(0)))
        _ = try builder.addBinding(symbol: a, scope: root, program: cycle)
        let snapshot = try builder.finish(), graph = try graph(snapshot, [(1, root, nil, [])], limits)
        var cycleSession = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 0, limits: limits)
        do {
            _ = try evaluateMOSBinding(a, invocation: 1, from: snapshot, session: &cycleSession)
            Issue.record("A cycle must fail")
        } catch { #expect(error == .circularInvocationBinding(invocation: 1, symbol: a)) }
        #expect(cycleSession.failureDiagnostic?.binding == a)
        let actual = try MOSInvocationActual(symbol: a, program: cycle, limits: limits)
        let overrideGraph = try self.graph(snapshot, [(1, root, nil, [actual])], limits)
        var overrideSession = try MOSEvaluationSession(snapshot: snapshot, graph: overrideGraph, seed: 0, limits: limits)
        do {
            _ = try evaluateMOSBinding(a, invocation: 1, from: snapshot, session: &overrideSession)
            Issue.record("Root actual self-reference must fail")
        } catch { #expect(error == .circularInvocationBinding(invocation: 1, symbol: a)) }
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 0, limits: limits)
        do {
            _ = try evaluateMOSProgram(failing, invocation: 1, lexicalScope: root, from: snapshot, session: &session)
            Issue.record("Division by zero must fail")
        } catch { #expect(error == .invalidArithmetic) }
        let retained = session.retainedBytes, peak = session.peakOwnedBufferBytes, steps = session.evaluationSteps
        #expect(session.randomDraws == 1 && session.failureDiagnostic?.cause == .invalidArithmetic)
        do {
            _ = try evaluateMOSProgram(failing, invocation: 1, lexicalScope: root, from: snapshot, session: &session)
            Issue.record("A poisoned session must fail")
        } catch { #expect(error == .poisonedSession) }
        #expect(session.randomDraws == 1 && session.evaluationSteps == steps)
        #expect(session.retainedBytes == retained && session.peakOwnedBufferBytes == peak)
    }

    @Test func functionRecursionAndRuntimeDepthAreIndependentOfASTDepth() throws {
        let admitted = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: admitted)
        let root = try builder.addScope(parent: nil), f = try builder.intern("f")
        let recurse = try builder.addProgram(.function(f, arguments: []))
        let recursiveID = try builder.addFunction(symbol: f, scope: root, parameters: [], program: recurse)
        let snapshot = try builder.finish(), graph = try graph(snapshot, [(1, root, nil, [])], admitted)
        var recursive = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: admitted)
        do {
            _ = try evaluateMOSProgram(recurse, invocation: 1, lexicalScope: root, from: snapshot, session: &recursive)
            Issue.record("Recursion must fail")
        } catch { #expect(error == .recursiveFunction(recursiveID)) }
        var shallowBuilder = MOSDeclarationSnapshotBuilder(limits: admitted)
        let shallowRoot = try shallowBuilder.addScope(parent: nil), a = try shallowBuilder.intern("a"), b = try shallowBuilder.intern("b")
        let callA = try shallowBuilder.addProgram(.function(a, arguments: [])), callB = try shallowBuilder.addProgram(.function(b, arguments: []))
        let result = try shallowBuilder.addProgram(.literal(1))
        _ = try shallowBuilder.addFunction(symbol: a, scope: shallowRoot, parameters: [], program: callB)
        _ = try shallowBuilder.addFunction(symbol: b, scope: shallowRoot, parameters: [], program: result)
        let shallow = try shallowBuilder.finish(), shallowGraph = try self.graph(shallow, [(1, shallowRoot, nil, [])], admitted)
        var session = try MOSEvaluationSession(snapshot: shallow, graph: shallowGraph, seed: 1, limits: limits(functionDepth: 1))
        do {
            _ = try evaluateMOSProgram(callA, invocation: 1, lexicalScope: shallowRoot, from: shallow, session: &session)
            Issue.record("Runtime function depth must be bounded")
        } catch { #expect(error == .limitExceeded(.functionDepth)) }
    }

    @Test func workCapacityCancellationAndSnapshotIdentityRejectEvaluation() throws {
        let admitted = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: admitted)
        let root = try builder.addScope(parent: nil)
        let value = try builder.addProgram(.binary(.add, .literal(1), .literal(2)))
        let snapshot = try builder.finish(), graph = try graph(snapshot, [(1, root, nil, [])], admitted)
        var short = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits(steps: 1))
        do {
            _ = try evaluateMOSProgram(value, invocation: 1, lexicalScope: root, from: snapshot, session: &short)
            Issue.record("Work exhaustion must fail")
        } catch { #expect(error == .limitExceeded(.evaluationSteps)) }
        #expect(short.failureDiagnostic?.cause == .limitExceeded(.evaluationSteps))
        let baseline = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: admitted)
        let exact = baseline.retainedBytes
        var full = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits(bytes: exact))
        do {
            _ = try evaluateMOSProgram(value, invocation: 1, lexicalScope: root, from: snapshot, session: &full)
            Issue.record("No stack capacity remains")
        } catch { #expect(error == .limitExceeded(.retainedBytes)) }
        #expect(full.failureDiagnostic != nil)
        var second = MOSDeclarationSnapshotBuilder(limits: admitted)
        _ = try second.addScope(parent: nil)
        let other = try second.finish()
        var identity = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: admitted)
        do {
            _ = try evaluateMOSProgram(value, invocation: 1, lexicalScope: root, from: other, session: &identity)
            Issue.record("Foreign snapshots must fail before dereference")
        } catch { #expect(error == .conditionMismatch) }
    }

    @Test func completeRequestCacheReuseRejectsChangedConditionsAndProfile() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil), model = try builder.intern("m"), l = try builder.intern("l")
        let value = try builder.addProgram(.literal(2))
        let snapshot = try builder.finish(), graph = try graph(snapshot, [(1, root, nil, [])], limits)
        let request = try MOSResolutionRequest(instance: "M1", scope: root, scopeInstantiation: 1,
            modelReference: model, profile: .coreStrictV1, bindings: [MOSExpressionBinding(symbol: l, program: value)],
            geometryScale: 1, seed: 1, limits: limits)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        try session.beginRequest(request, from: snapshot)
        #expect(try session.cachedInstance(for: request) == nil)
        let values = [MOSNumericParameter(symbol: l, value: 2)]
        try session.storeInstance(values, for: request)
        try session.beginRequest(request, from: snapshot)
        #expect(try session.cachedInstance(for: request) == values)
        let changed = try MOSResolutionRequest(instance: "M1", scope: root, scopeInstantiation: 1,
            modelReference: model, profile: .coreStrictV1, bindings: request.bindings,
            geometryScale: 2, seed: 1, limits: limits)
        do { try session.beginRequest(changed, from: snapshot); Issue.record("Changed request conditions must fail") }
        catch { #expect(error == .conditionMismatch) }
        #expect(session.failureDiagnostic?.cause == .conditionMismatch)
        let changedProfile = try MOSResolutionRequest(instance: "M2", scope: root, scopeInstantiation: 1,
            modelReference: model, profile: .pinnedNgspiceNormalV1, bindings: request.bindings,
            geometryScale: 1, seed: 1, limits: limits)
        var pinned = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        try pinned.beginRequest(request, from: snapshot)
        do { try pinned.beginRequest(changedProfile, from: snapshot); Issue.record("Changed profile must fail") }
        catch { #expect(error == .conditionMismatch) }
    }

    @Test func diagnosticTruncationAndCancellationKeepPreadmittedFailureEvidence() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil), model = try builder.intern("m")
        let value = try builder.addProgram(.literal(2))
        let snapshot = try builder.finish(), graph = try graph(snapshot, [(1, root, nil, [])], limits)
        var cancelled = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits,
            control: CancelMOSNumericalWork())
        do {
            _ = try evaluateMOSProgram(value, invocation: 1, lexicalScope: root, from: snapshot, session: &cancelled)
            Issue.record("Cancellation must fail")
        } catch { #expect(error == .cancelled) }
        #expect(cancelled.failureDiagnostic?.cause == .cancelled && cancelled.randomDraws == 0)
        let request = try MOSResolutionRequest(instance: String(repeating: "M", count: 8192), scope: root,
            scopeInstantiation: 1, modelReference: model, profile: .coreStrictV1, bindings: [],
            geometryScale: 1, seed: 1, limits: limits)
        var truncated = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        try truncated.beginRequest(request, from: snapshot)
        truncated.poison(.missingModel(model))
        let bytes = truncated.retainedBytes
        #expect(truncated.failureDiagnostic?.isTruncated == true)
        #expect(truncated.failureDiagnostic?.instance == nil)
        #expect(truncated.failureDiagnostic?.invocation == 1 && truncated.failureDiagnostic?.modelReference == model)
        truncated.recordCandidate(MOSCandidateEvidence(declaration: MOSDeclarationID(0), disposition: .selected))
        truncated.poison(.invalidRequest)
        #expect(truncated.failureDiagnostic?.cause == .missingModel(model))
        #expect(truncated.retainedBytes == bytes && truncated.failureDiagnostic?.candidates.isEmpty == true)
        #expect(throws: MOSResolutionFailure.nonFiniteValue(model)) {
            try MOSInvocationActual(symbol: model, constant: .infinity, limits: limits)
        }
    }

    @Test func lexicalOwnerWalksChargeEveryProgramAndFunctionHop() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil), first = try builder.addScope(parent: root)
        let second = try builder.addScope(parent: first), third = try builder.addScope(parent: second)
        let f = try builder.intern("f"), literal = try builder.addProgram(.literal(7))
        _ = try builder.addFunction(symbol: f, scope: root, parameters: [], program: literal)
        let call = try builder.addProgram(.function(f, arguments: []))
        let snapshot = try builder.finish()
        let graph = try graph(snapshot, [(1, root, nil, []), (2, first, 1, []),
            (3, second, 2, []), (4, third, 3, [])], limits)
        var direct = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        var deep = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        #expect(try evaluateMOSProgram(literal, invocation: 1, lexicalScope: root, from: snapshot, session: &direct) == 7)
        #expect(try evaluateMOSProgram(literal, invocation: 4, lexicalScope: root, from: snapshot, session: &deep) == 7)
        #expect(deep.evaluationSteps >= direct.evaluationSteps + 6)
        var rootCall = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        var nestedCall = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        #expect(try evaluateMOSProgram(call, invocation: 1, lexicalScope: root, from: snapshot, session: &rootCall) == 7)
        #expect(try evaluateMOSProgram(call, invocation: 4, lexicalScope: third, from: snapshot, session: &nestedCall) == 7)
        #expect(nestedCall.evaluationSteps >= rootCall.evaluationSteps + 9)
        var bounded = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: self.limits(steps: 4))
        do {
            _ = try evaluateMOSProgram(literal, invocation: 4, lexicalScope: root, from: snapshot, session: &bounded)
            Issue.record("Lexical traversal must consume the session work budget")
        } catch { #expect(error == .limitExceeded(.evaluationSteps)) }
    }

    @Test func requestIdentityIgnoresRetainedCapacityAndReusesAdmittedValues() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil), model = try builder.intern("m"), l = try builder.intern("l")
        let value = try builder.addProgram(.literal(2))
        let snapshot = try builder.finish(), graph = try graph(snapshot, [(1, root, nil, [])], limits)
        let compactBindings = [MOSExpressionBinding(symbol: l, program: value)]
        var spareBindings = compactBindings
        spareBindings.reserveCapacity(32)
        let compact = try MOSResolutionRequest(instance: "M1", scope: root, scopeInstantiation: 1,
            modelReference: model, profile: .coreStrictV1, bindings: compactBindings, geometryScale: 1, seed: 1, limits: limits)
        let spare = try MOSResolutionRequest(instance: "M1", scope: root, scopeInstantiation: 1,
            modelReference: model, profile: .coreStrictV1, bindings: spareBindings, geometryScale: 1, seed: 1, limits: limits)
        #expect(compact.retainedBytes != spare.retainedBytes)
        #expect(compact == spare)
        #expect(Set([compact, spare]).count == 1)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        try session.beginRequest(compact, from: snapshot)
        let values = [MOSNumericParameter(symbol: l, value: 2)]
        try session.storeInstance(values, for: compact)
        try session.beginRequest(spare, from: snapshot)
        #expect(try session.cachedInstance(for: spare) == values)
        #expect(session.failureDiagnostic == nil)
    }

    @Test func rejectedIncomingRequestOwnsDiagnosticInsteadOfPreviousAttempt() throws {
        let limits = try limits()
        var builder = MOSDeclarationSnapshotBuilder(limits: limits)
        let root = try builder.addScope(parent: nil), model = try builder.intern("m")
        let snapshot = try builder.finish(), graph = try graph(snapshot, [(1, root, nil, [])], limits)
        let first = try MOSResolutionRequest(instance: "M1", scope: root, scopeInstantiation: 1,
            modelReference: model, profile: .coreStrictV1, bindings: [], geometryScale: 1, seed: 1, limits: limits)
        let incomingSource = MOSSourceOccurrence(captureID: "capture2", occurrenceID: 2, path: "m2.sp",
            line: 2, column: 1, statementByteOffset: nil, statementOrdinal: nil)
        let incoming = try MOSResolutionRequest(source: incomingSource, instance: "M2", scope: MOSScopeID(999),
            scopeInstantiation: 999, modelReference: MOSSymbolID(999), profile: .coreStrictV1,
            bindings: [], geometryScale: 1, seed: 2, limits: limits)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 1, limits: limits)
        try session.beginRequest(first, from: snapshot)
        session.recordGeometry(raw: MOSInputGeometry(length: 1, width: 2), normalized: nil, selection: nil)
        try session.recordCandidates(0..<0, family: true)
        session.recordCandidate(MOSCandidateEvidence(declaration: MOSDeclarationID(0), disposition: .selected))
        do { try session.beginRequest(incoming, from: snapshot); Issue.record("A changed seed must fail") }
        catch { #expect(error == .conditionMismatch) }
        let failureDiagnostic = session.failureDiagnostic
        let diagnostic = try #require(failureDiagnostic)
        #expect(diagnostic.instance == "M2" && diagnostic.instanceSource == incomingSource)
        #expect(diagnostic.invocation == 999 && diagnostic.scope == MOSScopeID(999))
        #expect(diagnostic.modelReference == MOSSymbolID(999))
        #expect(diagnostic.rawGeometry == nil && diagnostic.normalizedGeometry == nil && diagnostic.selectionGeometry == nil)
        #expect(diagnostic.candidateRange == nil && diagnostic.candidates.isEmpty)
    }

    private func graph(_ snapshot: MOSDeclarationSnapshot,
                       _ entries: [(UInt64, MOSScopeID, UInt64?, [MOSInvocationActual])],
                       _ limits: MOSResolutionLimits) throws(MOSResolutionFailure) -> MOSInvocationGraph {
        var input: [MOSScopeInvocation] = []
        for entry in entries {
            input.append(try MOSScopeInvocation(id: entry.0, scope: entry.1, callerInvocationID: entry.2,
                actuals: entry.3, limits: limits))
        }
        return try MOSInvocationGraph(snapshot: snapshot, invocations: input, limits: limits)
    }

    private func limits(steps: UInt64 = 100_000, bytes: UInt64 = 1_000_000, functionDepth: Int = 16)
        throws(MOSResolutionFailure) -> MOSResolutionLimits {
        try MOSResolutionLimits(maximumRetainedBytes: bytes, maximumDiagnosticBytes: 4096,
            maximumScopeDepth: 16, maximumSymbols: 64, maximumScopes: 16, maximumInvocations: 64,
            maximumInvocationBindings: 256, maximumDeclarations: 64, maximumPrograms: 64,
            maximumBindings: 64, maximumFunctions: 16, maximumFunctionDepth: functionDepth,
            maximumExpressionNodes: 128, maximumExpressionDepth: 64, maximumCandidates: 64,
            maximumCacheEntries: 64, maximumEvaluationSteps: steps)
    }
}

private struct CancelMOSNumericalWork: MOSResolutionControlling {
    func checkCancellation() throws(MOSResolutionFailure) {}
    func charge(_ kind: MOSResolutionWork, units: UInt64) throws(MOSResolutionFailure) {
        if kind == .evaluationSteps { throw .cancelled }
    }
}

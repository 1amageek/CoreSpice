import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

@Suite("Concrete lexical MOS selection")
struct MOSSelectionTests {
    @Test func exactNameTakesPriorityAndOmittedDimensionsRemainAbsent() throws {
        var f = try MOSSelectionFixture()
        _ = try f.model("n.1")
        let exact = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos,
            level: nil, version: nil, coefficients: [], source: MOSSelectionFixture.source("exact"))
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let result = try resolveMOS(f.request([]), from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        #expect(result.declaration == exact && result.release == .level1)
        #expect(result.releaseOrigin == .defaulted(.coreStrictV1))
        #expect(result.rawGeometry.length == nil && result.normalizedGeometry.width == nil)
        #expect(result.candidates.count == 1 && result.candidates[0].bounds == nil)
    }

    @Test func nearestFamilyRefusalDoesNotFallbackToParentExactModel() throws {
        var f = try MOSSelectionFixture()
        _ = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos,
            level: 1, version: nil, coefficients: [], source: MOSSelectionFixture.source("parent"))
        let child = try f.builder.addScope(parent: f.root)
        _ = try f.model("n.1", scope: child, level: 54, version: "4.5")
        let dimensions = try [f.binding("l", 8e-6), f.binding("w", 8e-6)]
        let snapshot = try f.finish()
        let graph = try f.graph(snapshot, invocations: [
            try MOSScopeInvocation(id: 1, scope: f.root, callerInvocationID: nil, actuals: [], limits: f.limits),
            try MOSScopeInvocation(id: 2, scope: child, callerInvocationID: 1, actuals: [], limits: f.limits)
        ])
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        #expect(throws: MOSResolutionFailure.osdiBindingRequired(level: 54, version: "4.5", source: MOSSelectionFixture.source("n.1"))) {
            try resolveMOS(f.request(dimensions, scope: child, invocation: 2), from: snapshot,
                schemas: StandardMOSModelSchemas(), session: &session)
        }
    }








    @Test func nonLexicalCallerModelNeverLeaksIntoCallee() throws {
        var f = try MOSSelectionFixture()
        let caller = try f.builder.addScope(parent: f.root), callee = try f.builder.addScope(parent: f.root)
        _ = try f.builder.addModel(name: "n", scope: caller, polarity: .nmos, level: 1,
            version: nil, coefficients: [], source: MOSSelectionFixture.source("caller"))
        let snapshot = try f.finish()
        let graph = try f.graph(snapshot, invocations: [
            try MOSScopeInvocation(id: 1, scope: f.root, callerInvocationID: nil, actuals: [], limits: f.limits),
            try MOSScopeInvocation(id: 2, scope: caller, callerInvocationID: 1, actuals: [], limits: f.limits),
            try MOSScopeInvocation(id: 3, scope: callee, callerInvocationID: 2, actuals: [], limits: f.limits)
        ])
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        #expect(throws: MOSResolutionFailure.missingModel(f.model)) {
            try resolveMOS(f.request([], scope: callee, invocation: 3), from: snapshot,
                schemas: StandardMOSModelSchemas(), session: &session)
        }
    }

    @Test func modelCacheUsesDeclarationOwnerAndInstanceSlotsUseCompleteRequestIdentity() throws {
        var f = try MOSSelectionFixture()
        let child = try f.builder.addScope(parent: f.root), p = try f.builder.intern("p")
        let one = try f.builder.addProgram(.literal(1)), two = try f.builder.addProgram(.literal(2))
        _ = try f.builder.addBinding(symbol: p, scope: f.root, program: one)
        let rand = try f.builder.intern("rand"), kp = try f.builder.intern("kp"), vto = try f.builder.intern("vto")
        let random = try f.builder.addProgram(.function(rand, arguments: []))
        let parameter = try f.builder.addProgram(.reference(p))
        _ = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos, level: 1, version: nil,
            coefficients: [MOSExpressionBinding(symbol: kp, program: random), MOSExpressionBinding(symbol: vto, program: parameter)],
            source: MOSSelectionFixture.source("root"))
        let snapshot = try f.finish()
        let graph = try f.graph(snapshot, invocations: [
            try MOSScopeInvocation(id: 1, scope: f.root, callerInvocationID: nil, actuals: [], limits: f.limits),
            try MOSScopeInvocation(id: 2, scope: child, callerInvocationID: 1,
                actuals: [try MOSInvocationActual(symbol: p, program: two, limits: f.limits)], limits: f.limits)
        ])
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let values = [MOSExpressionBinding(symbol: f.l, program: random)]
        let request = try f.request(values, scope: child, invocation: 2)
        let first = try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        #expect(session.randomDraws == 2)
        #expect(first.modelCoefficients.first { $0.symbol == vto }?.value == 1)
        _ = try resolveMOS(request, from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        #expect(session.randomDraws == 2)
        let second = try resolveMOS(f.request(values, scope: child, invocation: 2, instance: "M2"),
            from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        #expect(session.randomDraws == 3 && first.modelCoefficients == second.modelCoefficients)
        #expect(first.rawGeometry.length != second.rawGeometry.length)
    }

    @Test func pinnedExactSameNameKeepsFirstCardWithoutEvaluatingLaterCard() throws {
        var f = try MOSSelectionFixture()
        let first = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos, level: 1,
            version: nil, coefficients: [], source: MOSSelectionFixture.source("first"))
        let missing = try f.builder.intern("missing"), kp = try f.builder.intern("kp")
        let invalid = try f.builder.addProgram(.reference(missing))
        _ = try f.builder.addModel(name: "n", scope: f.root, polarity: .nmos, level: 1, version: nil,
            coefficients: [MOSExpressionBinding(symbol: kp, program: invalid)], source: MOSSelectionFixture.source("second"))
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let result = try resolveMOS(f.request([], profile: .pinnedNgspiceNormalV1), from: snapshot,
            schemas: StandardMOSModelSchemas(), session: &session)
        #expect(result.declaration == first && result.candidates.count == 1)
    }

}

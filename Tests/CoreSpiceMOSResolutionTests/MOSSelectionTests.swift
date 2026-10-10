import CoreSpiceMOSContracts
import CoreSpiceMOSResolution
import Testing

@Suite("Concrete lexical MOS selection")
struct MOSSelectionTests {
    @Test func exactNameTakesPriorityAndOmittedDimensionsRemainAbsent() throws {
        var f = try MOSSelectionFixture()
        _ = try f.bin("n.1")
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
        _ = try f.bin("n.1", scope: child)
        let dimensions = try [f.binding("l", 8e-6), f.binding("w", 8e-6)]
        let snapshot = try f.finish()
        let graph = try f.graph(snapshot, invocations: [
            try MOSScopeInvocation(id: 1, scope: f.root, callerInvocationID: nil, actuals: [], limits: f.limits),
            try MOSScopeInvocation(id: 2, scope: child, callerInvocationID: 1, actuals: [], limits: f.limits)
        ])
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        #expect(throws: MOSResolutionFailure.noMatchingBin(f.model)) {
            try resolveMOS(f.request(dimensions, scope: child, invocation: 2), from: snapshot,
                schemas: StandardMOSModelSchemas(), session: &session)
        }
    }

    @Test func strictAmbiguityDependsOnCurrentGeometryAndUsesClosedBounds() throws {
        var f = try MOSSelectionFixture()
        let first = try f.bin("n.1")
        _ = try f.bin("n.2", bounds: [2e-6, 3e-6, 1e-6, 2e-6])
        let inside = try [f.binding("l", 1.5e-6), f.binding("w", 1e-6)]
        let touching = try [f.binding("l", 2e-6), f.binding("w", 1e-6)]
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let result = try resolveMOS(f.request(inside), from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        #expect(result.declaration == first && result.candidates.count == 2)
        #expect(throws: MOSResolutionFailure.ambiguousModel(f.model)) {
            try resolveMOS(f.request(touching, instance: "M2"), from: snapshot,
                schemas: StandardMOSModelSchemas(), session: &session)
        }
        #expect(throws: MOSResolutionFailure.poisonedSession) {
            try resolveMOS(f.request(inside), from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
        }
    }

    @Test func pinnedFirstCardAndReverseRegistrationAvoidDiscardedExpressions() throws {
        var f = try MOSSelectionFixture()
        let first = try f.bin("n.1")
        let absent = try f.builder.intern("absent")
        let bad = try f.builder.addProgram(.reference(absent))
        let vth = try f.builder.intern("vth0")
        _ = try f.bin("n.1", extras: [MOSExpressionBinding(symbol: vth, program: bad)])
        let second = try f.bin("n.2")
        let dimensions = try [f.binding("l", 1.5e-6), f.binding("w", 1.5e-6)]
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let result = try resolveMOS(f.request(dimensions, profile: .pinnedNgspiceNormalV1), from: snapshot,
            schemas: StandardMOSModelSchemas(), session: &session)
        #expect(result.declaration == second && result.candidates.count == 1)
        #expect(result.declaration != first)
    }

    @Test func pinnedEndpointToleranceAndMissingBoundsAreRecorded() throws {
        var f = try MOSSelectionFixture()
        let good = try f.bin("n.1", bounds: [1e-6, 1e-6, 1e-6, 1e-6])
        _ = try f.bin("n.2", bounds: [nil, 2e-6, 1e-6, 2e-6])
        let dimensions = try [f.binding("l", 1e-6 + 0.5e-9), f.binding("w", 1e-6)]
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        let result = try resolveMOS(f.request(dimensions, profile: .pinnedNgspiceNormalV1), from: snapshot,
            schemas: StandardMOSModelSchemas(), session: &session)
        #expect(result.declaration == good)
        #expect(result.candidates.map(\.disposition) == [.missingBounds, .selected])
        #expect(result.candidates[0].bounds?.missingMask == 1)
    }

    @Test func strictDuplicateCardFailsEvenOutsideCurrentGeometry() throws {
        var f = try MOSSelectionFixture()
        _ = try f.bin("n.1"); _ = try f.bin("n.1", bounds: [4e-6, 5e-6, 4e-6, 5e-6])
        let dimensions = try [f.binding("l", 1e-6), f.binding("w", 1e-6)]
        let snapshot = try f.finish(), graph = try f.graph(snapshot)
        let name = try #require(snapshot.symbol(named: "n.1"))
        var session = try MOSEvaluationSession(snapshot: snapshot, graph: graph, seed: 42, limits: f.limits)
        #expect(throws: MOSResolutionFailure.duplicateModel(name)) {
            try resolveMOS(f.request(dimensions), from: snapshot, schemas: StandardMOSModelSchemas(), session: &session)
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

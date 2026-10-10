import CoreSpiceIO
import Testing

@Suite("Shared-session node-voltage resolution", .timeLimit(.minutes(1)))
struct NodeVoltageResolutionTests {
    private let a = Node(id: 1)
    private let b = Node(id: 2)
    private var circuit: CircuitIR {
        CircuitIR(nodes: [.ground, a, b], branches: [], instances: [], nodeNames: [a: "A", b: "B"])
    }
    private var resolver: any SPICENodeVoltageResolving { SPICENodeVoltageResolver() }
    private var limits: MOSResolutionLimits {
        get throws {
            try MOSResolutionLimits(maximumRetainedBytes: 1024 * 1024, maximumDiagnosticBytes: 4096,
                maximumScopeDepth: 32, maximumSymbols: 1024, maximumScopes: 128,
                maximumInvocations: 128, maximumInvocationBindings: 1024, maximumDeclarations: 1024,
                maximumPrograms: 4096, maximumBindings: 4096, maximumFunctions: 128, maximumFunctionDepth: 32,
                maximumExpressionNodes: 8192, maximumExpressionDepth: 64, maximumCandidates: 1024,
                maximumCacheEntries: 4096, maximumEvaluationSteps: 100_000)
        }
    }
    private func compile(_ assignments: [String: ParsedParameterValue],
                         parameters: [String: ParsedExpression] = [:]) throws -> CompiledNetlist {
        try NetlistLowering.compile(.init(parameters: parameters, initialConditions: assignments), limits: limits)
    }
    private func begin(_ compiled: CompiledNetlist) throws -> NetlistLoweringSession {
        try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 13)
    }

    @Test func ordinaryExpressionsAliasesAndActualEvaluationCause() throws {
        let compiled = try compile(["a": .expression(.binaryOperation(.multiply, .identifier("gain"), .literal(3))),
            "B": .boolean(true), "GND": .numeric(0), "0": .numeric(0)], parameters: ["gain": .literal(2)])
        var session = try begin(compiled)
        let values = try resolver.resolve(.initialConditions, compiled: compiled, session: &session, circuit: circuit)
        #expect(values[a] == 6); #expect(values[b] == 1); #expect(values[.ground] == 0)
        let unicode = try compile(["ä": .numeric(4)])
        var unicodeSession = try begin(unicode)
        let unicodeCircuit = CircuitIR(nodes: [a], branches: [], instances: [], nodeNames: [a: "Ä"])
        #expect(try resolver.resolve(.initialConditions, compiled: unicode, session: &unicodeSession, circuit: unicodeCircuit)[a] == 4)
        let missing = try compile(["a": .expression(.identifier("absent"))])
        var failed = try begin(missing)
        do {
            _ = try resolver.resolve(.initialConditions, compiled: missing, session: &failed, circuit: circuit)
            Issue.record("Missing parameter unexpectedly resolved")
        } catch {
            guard case .evaluation(let name, let cause) = error,
                  let failure = cause as? MOSResolutionFailure, case .undefinedParameter = failure else { throw error }
            #expect(name == "a")
        }
    }

    @Test func semanticFailurePoisonsAndWrongCompiledIdentityIsRejected() throws {
        for assignments in [["missing": ParsedParameterValue.numeric(1)], ["gnd": .numeric(1)]] {
            let compiled = try compile(assignments)
            var session = try begin(compiled)
            do {
                _ = try resolver.resolve(.initialConditions, compiled: compiled, session: &session, circuit: circuit)
                Issue.record("Invalid assignment unexpectedly resolved")
            } catch {
                switch error { case .unknownNode, .nonzeroGround: break; default: throw error }
            }
            do { try session.lower(); Issue.record("Invalid node assignment left the run usable") }
            catch let error as MOSResolutionFailure { #expect(error == .poisonedSession) }
        }
        let first = try compile([:]), other = try compile([:])
        var session = try begin(first)
        do {
            _ = try resolver.resolve(.initialConditions, compiled: other, session: &session, circuit: circuit)
            Issue.record("Wrong compiled identity was accepted")
        } catch { guard case .compiledIdentityMismatch = error else { throw error } }
        for number in [Double.nan, .infinity, -.infinity] {
            #expect(throws: MOSResolutionFailure.self) { _ = try compile(["a": .numeric(number)]) }
        }
    }

    @Test func parserLastAssignmentAndControlAliasConsumeOneDraw() async throws {
        let parsed = try await SPICEIO.parse("node aliases\nR1 a 0 1k\n.ic V(A)={rand()}\n.ic V(a)={rand()}\n.nodeset V(A)=3\n.end\n").get()
        #expect(parsed.initialConditions.count == 1)
        let compiled = try NetlistLowering.compile(parsed, limits: limits)
        var session = try begin(compiled)
        try session.lower()
        let emittedCircuit = session.circuit
        let actual = try #require(emittedCircuit)
        let values = try resolver.resolve(.initialConditions, compiled: compiled, session: &session, circuit: actual)
        let again = try resolver.resolve(.initialConditions, compiled: compiled, session: &session, circuit: actual)
        #expect(values == again); #expect(values.count == 1)
        let slots = try resolver.resolve(.nodeSets, compiled: compiled, session: &session, circuit: actual)
        #expect(slots.values.first == 3)
        let lowered = try session.finish()
        #expect(lowered.evaluationProvenance.randomDraws == 1)
    }

    @Test func boundedExpressionsAndIdenticalAliasesOwnOutput() throws {
        let compiled = try compile(["a": .expression(.binaryOperation(.add, .literal(1), .literal(2))),
            "b": .boolean(true), "B": .boolean(true), "0": .numeric(0), "GND": .boolean(false)])
        var session = try begin(compiled)
        let resources = NodeVoltageTestResources()
        var first: SPICEOwnedNodeVoltages? = try resolver.resolveBounded(.initialConditions, compiled: compiled,
            session: &session, circuit: circuit, resources: resources)
        #expect(first?.bindings.count == 3)
        var observed: [Node: Double] = [:]
        for binding in try #require(first).bindings { observed[binding.node] = binding.voltage }
        #expect(observed[a] == 3); #expect(observed[b] == 1); #expect(observed[.ground] == 0)
        let live = resources.used(.liveOwnedBytes); #expect(live > 0)
        #expect(resources.used(.temporaryBytes) == 0)
        var last = first; first = nil
        #expect(resources.used(.liveOwnedBytes) == live)
        #expect(last?.bindings.count == 3); last = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func boundedCapabilityAmbiguityAndSemanticRefusals() throws {
        let cases: [([String: ParsedParameterValue], CircuitIR, String)] = [
            (["Ä": .numeric(1)], circuit, "unicode"),
            (["a": .numericVector([1, 2])], circuit, "vector"),
            (["a": .numeric(1)], .init(nodes: [a, b], branches: [], instances: [], nodeNames: [a: "a", b: "A"]), "names"),
            (["missing": .numeric(1)], circuit, "unknown"),
            (["gnd": .numeric(1)], circuit, "ground")
        ]
        for (assignments, selected, reason) in cases {
            let compiled = try compile(assignments)
            var session = try begin(compiled)
            do {
                _ = try resolver.resolveBounded(.initialConditions, compiled: compiled, session: &session,
                    circuit: selected, resources: NodeVoltageTestResources())
                Issue.record("Invalid bounded assignment resolved: \(reason)")
            } catch {
                switch (reason, error) {
                case ("unicode", .unsupportedCapability(.unicodeNodeName)), ("vector", .unsupportedCapability(.nonscalarValue)),
                     ("names", .ambiguousCircuitName),
                     ("unknown", .boundedUnknownNode), ("ground", .nonzeroGround): break
                default: throw error
                }
            }
        }
    }

    @Test func conflictingHandBuiltCanonicalAssignmentsFailBeforeEvaluation() throws {
        do {
            _ = try compile(["A": .numeric(1), "a": .numeric(2)])
            Issue.record("Conflicting canonical scalar inputs compiled")
        } catch let error as MOSResolutionFailure { #expect(error == .invalidRequest) }
        let compiled = try compile(["A": .numeric(2), "a": .numeric(2)])
        var session = try begin(compiled)
        let values = try resolver.resolveBounded(.initialConditions, compiled: compiled,
            session: &session, circuit: circuit, resources: NodeVoltageTestResources())
        #expect(values.bindings.count == 1)
        #expect(values.bindings.first?.voltage == 2)
    }

    @Test(arguments: [false, true], [false, true])
    func finalControlOwnsOrdinaryAndBoundedAssignmentTruth(initial: Bool, staleDictionary: Bool) throws {
        let kind: SPICENodeVoltageAssignmentKind = initial ? .initialConditions : .nodeSets
        let controls: [ParsedControlStatement] = initial
            ? [.initialCondition(node: "a", voltage: .numeric(9), location: nil),
               .initialCondition(node: "A", voltage: .numeric(1), location: nil)]
            : [.nodeSet(node: "a", voltage: .numeric(9), location: nil),
               .nodeSet(node: "A", voltage: .numeric(1), location: nil)]
        let fallback: [String: ParsedParameterValue] = staleDictionary
            ? ["a": .string("stale projection"), "b": .numeric(2)] : [:]
        let source = ParsedNetlist(controls: controls,
            initialConditions: initial ? fallback : [:], nodeSets: initial ? [:] : fallback)
        let compiled = try NetlistLowering.compile(source, limits: limits)
        var session = try begin(compiled)
        let ordinary = try resolver.resolve(kind, compiled: compiled, session: &session, circuit: circuit)
        #expect(ordinary[a] == 1)
        #expect(ordinary[b] == (staleDictionary ? 2 : nil))
        let bounded = try resolver.resolveBounded(kind, compiled: compiled, session: &session,
            circuit: circuit, resources: NodeVoltageTestResources())
        #expect(bounded.bindings.count == (staleDictionary ? 2 : 1))
        #expect(bounded.bindings.first { $0.node == a }?.voltage == 1)
        #expect(bounded.bindings.first { $0.node == b }?.voltage == (staleDictionary ? 2 : nil))
    }

    @Test func boundedSharedQuotaAndCancellationPreserveActualCause() throws {
        for resources in [NodeVoltageTestResources(workLimit: 1), NodeVoltageTestResources(liveLimit: 1)] {
            let compiled = try compile(["a": .numeric(1)])
            var session = try begin(compiled)
            do {
                _ = try resolver.resolveBounded(.initialConditions, compiled: compiled, session: &session,
                    circuit: circuit, resources: resources)
                Issue.record("Bounded conversion ignored quota")
            } catch { guard case .resource(let cause) = error, cause is NodeVoltageTestResourceError else { throw error } }
            #expect(resources.used(.liveOwnedBytes) == 0); #expect(resources.used(.temporaryBytes) == 0)
        }
        let cancelled = NodeVoltageTestResources(); cancelled.setCancelled(true)
        let compiled = try compile([:]); var session = try begin(compiled)
        do {
            _ = try resolver.resolveBounded(.initialConditions, compiled: compiled, session: &session,
                circuit: circuit, resources: cancelled)
            Issue.record("Empty conversion ignored cancellation")
        } catch {
            guard case .resource(let cause) = error, let typed = cause as? NodeVoltageTestResourceError,
                  typed == .cancelled else { throw error }
        }
    }
}

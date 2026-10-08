import CoreSpiceIO
import Testing

@Suite struct NodeVoltageResolutionTests {
    private let a = Node(id: 1)
    private let b = Node(id: 2)
    private var circuit: CircuitIR {
        CircuitIR(nodes: [.ground, a, b], branches: [], instances: [], nodeNames: [a: "A", b: "B"])
    }
    private var resolver: any SPICENodeVoltageResolving { SPICENodeVoltageResolver() }
    private var evaluator: ExpressionEvaluator { ExpressionEvaluator(context: LoweringContext()) }

    @Test func ordinaryExpressionsAliasesAndActualEvaluationCause() throws {
        let context = LoweringContext(); context.setParameter("gain", value: 2)
        let values = try resolver.resolve(assignments: ["a": .expression(.binaryOperation(.multiply,
            .identifier("gain"), .literal(3))), "B": .boolean(true), "GND": .numeric(0), "0": .numeric(0)],
            circuit: circuit, evaluator: ExpressionEvaluator(context: context))
        #expect(values[a] == 6); #expect(values[b] == 1); #expect(values[.ground] == 0)
        let unicode = CircuitIR(nodes: [a], branches: [], instances: [], nodeNames: [a: "Ä"])
        #expect(try resolver.resolve(assignments: ["ä": .numeric(4)], circuit: unicode, evaluator: evaluator)[a] == 4)
        do {
            _ = try resolver.resolve(assignments: ["a": .expression(.identifier("absent"))], circuit: circuit, evaluator: evaluator)
            Issue.record("Missing parameter unexpectedly resolved")
        } catch {
            guard case .evaluation(let name, let cause) = error,
                  let lower = cause as? LoweringError,
                  case .undefinedParameter(let parameter, _) = lower else { throw error }
            #expect(name == "a"); #expect(parameter == "absent")
        }
    }

    @Test func ordinaryRefusesUnknownNonfiniteAndNonzeroGround() throws {
        do {
            _ = try resolver.resolve(assignments: ["missing": .numeric(1)], circuit: circuit, evaluator: evaluator)
            Issue.record("Unknown node unexpectedly resolved")
        } catch { guard case .unknownNode("missing") = error else { throw error } }
        for value in [Double.nan, .infinity, -.infinity] {
            do {
                _ = try resolver.resolve(assignments: ["a": .numeric(value)], circuit: circuit, evaluator: evaluator)
                Issue.record("Nonfinite voltage unexpectedly resolved")
            } catch { guard case .nonfiniteValue(let name, _) = error else { throw error }; #expect(name == "a") }
        }
        for name in ["0", "gnd", "GND"] {
            do {
                _ = try resolver.resolve(assignments: [name: .numeric(1)], circuit: circuit, evaluator: evaluator)
                Issue.record("Nonzero ground unexpectedly resolved")
            } catch { guard case .nonzeroGround = error else { throw error } }
        }
    }

    @Test func parserLastNormalizedAssignmentAndOrdinaryAliasPolicy() async throws {
        let parsed = try await SPICEIO.parse("initial assignments\n.ic V(A)=1 V(a)=2\n.nodeset V(B)=3 V(b)=4\n.end\n").get()
        #expect(parsed.initialConditions.count == 1); #expect(parsed.nodeSets.count == 1)
        #expect(try resolver.resolve(assignments: parsed.initialConditions, circuit: circuit, evaluator: evaluator)[a] == 2)
        #expect(try resolver.resolve(assignments: parsed.nodeSets, circuit: circuit, evaluator: evaluator)[b] == 4)
        let aliases: [String: ParsedParameterValue] = ["A": .numeric(1), "a": .numeric(2)]
        var expected: Double?
        for (_, value) in aliases { expected = try evaluator.evaluate(value) }
        #expect(try resolver.resolve(assignments: aliases, circuit: circuit, evaluator: evaluator)[a] == expected)
    }

    @Test func boundedScalarsGroundAndIdenticalAliasesOwnOutput() throws {
        let resources = NodeVoltageTestResources()
        var first: SPICEOwnedNodeVoltages? = try resolver.resolveBounded(assignments:
            ["a": .numeric(3), "A": .expression(.literal(3)), "b": .boolean(true), "0": .numeric(0), "GND": .boolean(false)],
            circuit: circuit, resources: resources)
        #expect(first?.bindings.count == 3)
        var observed: [Node: Double] = [:]
        for binding in try #require(first).bindings { observed[binding.node] = binding.voltage }
        #expect(observed[a] == 3); #expect(observed[b] == 1); #expect(observed[.ground] == 0)
        let live = resources.used(.liveOwnedBytes); #expect(live > 0)
        #expect(resources.used(.temporaryBytes) == 0)
        var last = first; first = nil
        #expect(resources.used(.liveOwnedBytes) == live)
        #expect(last?.bindings.count == 3)
        last = nil
        #expect(resources.used(.liveOwnedBytes) == 0)
    }

    @Test func boundedCapabilityAmbiguityAndSemanticRefusals() throws {
        func resolve(_ assignments: [String: ParsedParameterValue], _ selected: CircuitIR? = nil) throws(SPICENodeVoltageResolutionError) {
            _ = try resolver.resolveBounded(assignments: assignments, circuit: selected ?? circuit, resources: NodeVoltageTestResources())
        }
        do { try resolve(["a": .expression(.binaryOperation(.add, .literal(1), .literal(2)))])
            Issue.record("Nonliteral expression used an unaccounted evaluator")
        } catch { guard case .unsupportedCapability(.nonliteralExpression) = error else { throw error } }
        do { try resolve(["Ä": .numeric(1)])
            Issue.record("Unicode name used unaccounted normalization")
        } catch { guard case .unsupportedCapability(.unicodeNodeName) = error else { throw error } }
        do { try resolve(["a": .numericVector([1, 2])])
            Issue.record("Vector unexpectedly resolved as scalar")
        } catch { guard case .unsupportedCapability(.nonscalarValue) = error else { throw error } }
        do { try resolve(["A": .numeric(1), "a": .numeric(2)])
            Issue.record("Conflicting aliases unexpectedly coalesced")
        } catch { guard case .ambiguousBinding = error else { throw error } }
        let ambiguous = CircuitIR(nodes: [a, b], branches: [], instances: [], nodeNames: [a: "a", b: "A"])
        do { try resolve(["a": .numeric(1)], ambiguous)
            Issue.record("Ambiguous circuit names unexpectedly selected one node")
        } catch { guard case .ambiguousCircuitName = error else { throw error } }
        do { try resolve(["missing": .numeric(1)])
            Issue.record("Unknown bounded node unexpectedly resolved")
        } catch { guard case .boundedUnknownNode = error else { throw error } }
        do { try resolve(["a": .numeric(.infinity)])
            Issue.record("Nonfinite bounded voltage unexpectedly resolved")
        } catch { guard case .boundedNonfiniteValue = error else { throw error } }
        do { try resolve(["gnd": .numeric(1)])
            Issue.record("Nonzero bounded ground unexpectedly resolved")
        } catch { guard case .nonzeroGround = error else { throw error } }
    }

    @Test func boundedSharedQuotaAndCancellationPreserveActualCause() throws {
        for resources in [NodeVoltageTestResources(workLimit: 1), NodeVoltageTestResources(liveLimit: 1)] {
            do {
                _ = try resolver.resolveBounded(assignments: ["a": .numeric(1)], circuit: circuit, resources: resources)
                Issue.record("Bounded conversion ignored quota")
            } catch {
                guard case .resource(let cause) = error, cause is NodeVoltageTestResourceError else { throw error }
            }
            #expect(resources.used(.liveOwnedBytes) == 0)
            #expect(resources.used(.temporaryBytes) == 0)
        }
        let cancelled = NodeVoltageTestResources(); cancelled.setCancelled(true)
        do {
            _ = try resolver.resolveBounded(assignments: [:], circuit: circuit, resources: cancelled)
            Issue.record("Empty conversion ignored cancellation")
        } catch {
            guard case .resource(let cause) = error, let typed = cause as? NodeVoltageTestResourceError,
                  typed == .cancelled else { throw error }
        }
        let shared = NodeVoltageTestResources()
        try shared.charge(.tokens, units: 7)
        let empty = try resolver.resolveBounded(assignments: [:], circuit: circuit, resources: shared)
        #expect(empty.bindings.isEmpty); #expect(shared.work(.tokens) == 7)
        let result = try resolver.resolveBounded(assignments: ["a": .numeric(1)], circuit: circuit, resources: shared)
        #expect(result.bindings.count == 1); #expect(shared.work(.tokens) > 7)
    }
}

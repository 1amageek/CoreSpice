import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceParsedIR

/// Stateless shared resolver. Ordinary expression evaluation remains Lowering-owned.
public struct SPICENodeVoltageResolver: SPICENodeVoltageResolving {
    public init() {}

    public func resolve(assignments: [String: ParsedParameterValue], circuit: CircuitIR,
                        evaluator: ExpressionEvaluator) throws(SPICENodeVoltageResolutionError) -> [Node: Double] {
        guard !assignments.isEmpty else { return [:] }
        var nodesByName: [String: Node] = [:]
        nodesByName.reserveCapacity(circuit.nodeNames.count + 2)
        for (node, name) in circuit.nodeNames { nodesByName[name.lowercased()] = node }
        nodesByName["0"] = circuit.groundNode; nodesByName["gnd"] = circuit.groundNode
        var resolved: [Node: Double] = [:]
        for (name, value) in assignments {
            guard let node = nodesByName[name.lowercased()] else { throw .unknownNode(name) }
            let voltage: Double
            do { voltage = try evaluator.evaluate(value) }
            catch { throw .evaluation(nodeName: name, cause: error) }
            guard voltage.isFinite else { throw .nonfiniteValue(nodeName: name, value: voltage) }
            guard node != circuit.groundNode || voltage == 0 else { throw .nonzeroGround }
            resolved[node] = voltage
        }
        return resolved
    }

    public func resolveBounded(assignments: [String: ParsedParameterValue], circuit: CircuitIR,
                               resources: any SPICESourceResourceAccounting)
    throws(SPICENodeVoltageResolutionError) -> SPICEOwnedNodeVoltages {
        let work = SPICENodeVoltageWork(resources: resources)
        try work.check()
        var output = SPICEAccountedCollection<SPICENodeVoltageBinding>(storageKind: .liveOwnedBytes)
        for (index, assignment) in assignments.enumerated() {
            try work.step()
            let node = try resolveNode(assignment.key, circuit: circuit, index: index, work: work)
            let voltage: Double
            switch assignment.value {
            case .numeric(let value): voltage = value
            case .boolean(let value): voltage = value ? 1 : 0
            case .expression(.literal(let value)): voltage = value
            // FIXME(INCOMPLETE_IMPLEMENTATION): Bounded callers reach this branch for required nonliteral voltage expressions. A Lowering-owned cooperative evaluator must prove work/storage/cancellation before this branch can return success.
            case .expression: throw .unsupportedCapability(.nonliteralExpression)
            case .numericVector, .string: throw .unsupportedCapability(.nonscalarValue)
            }
            guard voltage.isFinite else { throw .boundedNonfiniteValue(assignmentIndex: index) }
            guard node != circuit.groundNode || voltage == 0 else { throw .nonzeroGround }
            var duplicate = false
            for binding in output {
                try work.step()
                if binding.node == node {
                    guard binding.voltage == voltage else { throw .ambiguousBinding(assignmentIndex: index) }
                    duplicate = true; break
                }
            }
            if !duplicate {
                do { try output.append(.init(node: node, voltage: voltage), resources: resources) }
                catch { throw .resource(cause: error) }
            }
        }
        try work.check()
        return .init(bindings: output)
    }

    private func resolveNode(_ name: String, circuit: CircuitIR, index: Int, work: SPICENodeVoltageWork)
    throws(SPICENodeVoltageResolutionError) -> Node {
        if try work.equalASCII(name, "0") { return circuit.groundNode }
        if try work.equalASCII(name, "gnd") { return circuit.groundNode }
        var selected: Node?
        for (node, candidate) in circuit.nodeNames {
            try work.step()
            if try work.equalASCII(name, candidate) {
                if let selected, selected != node { throw .ambiguousCircuitName(assignmentIndex: index) }
                selected = node
            }
        }
        guard let selected else { throw .boundedUnknownNode(assignmentIndex: index) }
        return selected
    }
}

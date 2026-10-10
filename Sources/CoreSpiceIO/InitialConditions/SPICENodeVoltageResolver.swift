import CoreSpiceIR
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceParsedIR

/// Stateless shared resolver. Ordinary expression evaluation remains Lowering-owned.
public struct SPICENodeVoltageResolver: SPICENodeVoltageResolving {
    public init() {}

    public func resolve(_ kind: SPICENodeVoltageAssignmentKind, compiled: CompiledNetlist,
                        session: inout NetlistLoweringSession, circuit: CircuitIR)
    throws(SPICENodeVoltageResolutionError) -> [Node: Double] {
        do throws(SPICENodeVoltageResolutionError) {
            guard compiled.sameStorage(as: session.compiled) else { throw .compiledIdentityMismatch }
            var assignments = SPICENodeVoltageAssignments(kind: kind, source: compiled.source)
            var nodesByName: [String: Node] = [:]
            nodesByName.reserveCapacity(circuit.nodeNames.count + 2)
            for (node, name) in circuit.nodeNames { nodesByName[name.lowercased()] = node }
            nodesByName["0"] = circuit.groundNode; nodesByName["gnd"] = circuit.groundNode
            var resolved: [Node: Double] = [:]
            while let assignment = try assignments.next(work: nil) {
                guard let node = nodesByName[assignment.name.lowercased()] else { throw .unknownNode(assignment.name) }
                let voltage = try evaluate(kind, name: assignment.name, compiled: compiled, session: &session)
                guard voltage.isFinite else { throw .nonfiniteValue(nodeName: assignment.name, value: voltage) }
                guard node != circuit.groundNode || voltage == 0 else { throw .nonzeroGround }
                resolved[node] = voltage
            }
            return resolved
        } catch {
            session.poison(.invalidRequest)
            throw error
        }
    }

    public func resolveBounded(_ kind: SPICENodeVoltageAssignmentKind, compiled: CompiledNetlist,
                               session: inout NetlistLoweringSession, circuit: CircuitIR,
                               resources: any SPICESourceResourceAccounting)
    throws(SPICENodeVoltageResolutionError) -> SPICEOwnedNodeVoltages {
        do throws(SPICENodeVoltageResolutionError) {
            guard compiled.sameStorage(as: session.compiled) else { throw .compiledIdentityMismatch }
            let work = SPICENodeVoltageWork(resources: resources)
            try work.check()
            var assignments = SPICENodeVoltageAssignments(kind: kind, source: compiled.source)
            var output = SPICEAccountedCollection<SPICENodeVoltageBinding>(storageKind: .liveOwnedBytes)
            var index = 0
            while let assignment = try assignments.next(work: work) {
                try work.step()
                let node = try resolveNode(assignment.name, circuit: circuit, index: index, work: work)
                switch assignment.value {
                case .numericVector, .string: throw .unsupportedCapability(.nonscalarValue)
                default: break
                }
                let voltage = try evaluate(kind, name: assignment.name, compiled: compiled, session: &session)
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
                index += 1
            }
            try work.check()
            return .init(bindings: output)
        } catch {
            session.poison(.invalidRequest)
            throw error
        }
    }

    private func evaluate(_ kind: SPICENodeVoltageAssignmentKind, name: String,
                          compiled: CompiledNetlist, session: inout NetlistLoweringSession)
    throws(SPICENodeVoltageResolutionError) -> Double {
        do {
            let address: NetlistScalarAddress
            switch kind {
            case .initialConditions: address = .initialCondition(node: name)
            case .nodeSets: address = .nodeSet(node: name)
            }
            return try session.evaluateScalar(compiled.scalarSlot(at: address))
        } catch { throw .evaluation(nodeName: name, cause: error) }
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

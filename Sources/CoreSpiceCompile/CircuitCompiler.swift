import CoreSpiceIR
import CoreSpiceMOSContracts

/// A type that compiles a circuit IR into an execution plan.
public protocol CircuitCompiler: Sendable {

    /// Compiles the given circuit into an execution plan.
    ///
    /// - Throws: ``CompileError`` if the circuit cannot be compiled.
    func compile(ir: CircuitIR) throws -> ExecutionPlan
}

/// The default circuit compiler.
///
/// Builds the MNA matrix topology from the circuit IR and packages
/// it into an ``ExecutionPlan``.
public struct StandardCompiler: CircuitCompiler {

    public init() {}

    public func compile(ir: CircuitIR) throws -> ExecutionPlan {
        guard !ir.instances.isEmpty else {
            throw CompileError.emptyCircuit
        }

        try admitMOSInstances(in: ir)
        let topology = MatrixTopology(ir: ir)

        return ExecutionPlan(
            ir: ir,
            topology: topology,
            matrixStructure: topology.structure,
            deviceNames: ir.instances.map(\.name)
        )
    }

    private func admitMOSInstances(in ir: CircuitIR) throws(CompileError) {
        var physicalNodes: Set<Node> = []
        guard ir.instances.contains(where: { $0.mos != nil || mosType(named: $0.typeName) != nil }) else { return }
        var ownershipCounts: [Node: Int] = [:]
        let inventory = Set(ir.nodes)
        for instance in ir.instances {
            for node in instance.nodes { physicalNodes.insert(node) }
            for node in instance.ownedNodes { ownershipCounts[node, default: 0] += 1 }
        }
        for instance in ir.instances {
            let expected = mosType(named: instance.typeName)
            guard let expected else {
                if instance.mos != nil { throw .unexpectedMOSStage(instance: instance.name) }
                continue
            }
            guard let stage = instance.mos else { throw .mosPreparationRequired(instance: instance.name) }
            guard case .prepared(let receipt) = stage else { throw .mosNotPrepared(instance: instance.name) }
            let resolved = receipt.identity.resolved
            guard resolved.instance == instance.name else { throw .mosInstanceMismatch(instance: instance.name, receipt: resolved.instance) }
            guard resolved.release.level == expected.level, resolved.release.isExecutable else {
                throw .mosReleaseMismatch(instance: instance.name, expectedLevel: expected.level, actual: resolved.release)
            }
            guard resolved.polarity == expected.polarity else {
                throw .mosPolarityMismatch(instance: instance.name, expected: expected.polarity, actual: resolved.polarity)
            }
            guard instance.nodes.count == 4 else {
                throw .mosPhysicalPortCount(instance: instance.name, actual: instance.nodes.count)
            }
            let topology = receipt.topology
            guard instance.ownedNodes.count == topology.auxiliaryNodeCount,
                  topology.localNodeCount == 4 + instance.ownedNodes.count else {
                throw .mosAuxiliaryNodeCount(instance: instance.name, expected: topology.auxiliaryNodeCount, actual: instance.ownedNodes.count)
            }
            for node in instance.nodes {
                guard node == ir.groundNode || inventory.contains(node) else { throw .mosNodeMissing(instance: instance.name, node: node.id) }
            }
            for node in instance.ownedNodes {
                guard inventory.contains(node) else { throw .mosNodeMissing(instance: instance.name, node: node.id) }
                guard node != ir.groundNode, !physicalNodes.contains(node), ownershipCounts[node] == 1 else {
                    throw .mosPrivateNodeAlias(instance: instance.name, node: node.id)
                }
            }
        }
    }

    private func mosType(named name: String) -> (level: Int, polarity: MOSPolarity)? {
        switch name {
        case "nmos", "nmos_l1": return (1, .nmos)
        case "pmos", "pmos_l1": return (1, .pmos)
        case "nmos_l2": return (2, .nmos)
        case "pmos_l2": return (2, .pmos)
        case "nmos_l3": return (3, .nmos)
        case "pmos_l3": return (3, .pmos)
        case "nmos_l49": return (49, .nmos)
        case "pmos_l49": return (49, .pmos)
        case "nmos_l54": return (54, .nmos)
        case "pmos_l54": return (54, .pmos)
        default: return nil
        }
    }

}

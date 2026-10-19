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

        for diode in ir.instances where diode.diode != nil {
            guard case .prepared(let receipt) = diode.diode,
                  diode.typeName == "diode", diode.name == receipt.identity.resolved.instance,
                  diode.nodes.count == 2, diode.nodes[0].id == receipt.identity.anodeNodeID,
                  diode.nodes[1].id == receipt.identity.cathodeNodeID,
                  diode.ownedNodes.isEmpty, diode.ownedBranches.isEmpty else {
                throw CompileError.diodePreparationRequired(instance: diode.name)
            }
        }
        for instance in ir.instances where ["nmos_l49", "pmos_l49", "nmos_l54", "pmos_l54"].contains(instance.typeName) {
            throw CompileError.osdiPreparationRequired(instance: instance.name)
        }
        try admitOSDIInstances(in: ir)
        try admitMOSInstances(in: ir)
        let topology = MatrixTopology(ir: ir)

        return ExecutionPlan(
            ir: ir,
            topology: topology,
            matrixStructure: topology.structure,
            deviceNames: ir.instances.map(\.name)
        )
    }

    private func admitOSDIInstances(in ir: CircuitIR) throws(CompileError) {
        guard ir.instances.contains(where: { $0.osdi != nil || $0.typeName == "osdi" }) else { return }
        let inventory = Set(ir.nodes), branchInventory = Set(ir.branches)
        let physical = Set(ir.instances.flatMap(\.nodes))
        var nodeOwners: [Node: Int] = [:], branchOwners: [Branch: Int] = [:]
        for instance in ir.instances {
            for node in instance.ownedNodes { nodeOwners[node, default: 0] += 1 }
            for branch in instance.ownedBranches { branchOwners[branch, default: 0] += 1 }
        }
        for instance in ir.instances where instance.osdi != nil || instance.typeName == "osdi" {
            guard instance.typeName == "osdi", instance.mos == nil, instance.diode == nil,
                  case .prepared(let receipt) = instance.osdi, instance.nodes.count <= receipt.topology.nodes.count else {
                throw .osdiPreparationRequired(instance: instance.name)
            }
            let topology = receipt.topology
            let external = Set(topology.nodes.prefix(instance.nodes.count).compactMap(\.activeUnknownIndex))
            var privateNodes = 0, privateBranches = 0
            for coordinate in 0..<topology.activeUnknownCount where !external.contains(coordinate) {
                guard let raw = topology.nodes.first(where: { $0.activeUnknownIndex == coordinate }) else { throw .osdiPreparationRequired(instance: instance.name) }
                if raw.isFlow { privateBranches += 1 } else { privateNodes += 1 }
            }
            guard instance.ownedNodes.count == privateNodes, instance.ownedBranches.count == privateBranches else {
                throw .osdiPreparationRequired(instance: instance.name)
            }
            for node in instance.nodes where node != ir.groundNode {
                guard inventory.contains(node) else { throw .osdiPreparationRequired(instance: instance.name) }
            }
            for node in instance.ownedNodes {
                guard node != ir.groundNode, inventory.contains(node), !physical.contains(node), nodeOwners[node] == 1 else {
                    throw .osdiPreparationRequired(instance: instance.name)
                }
            }
            for branch in instance.ownedBranches {
                guard branchInventory.contains(branch), branchOwners[branch] == 1 else { throw .osdiPreparationRequired(instance: instance.name) }
            }
        }
    }

    private func admitMOSInstances(in ir: CircuitIR) throws(CompileError) {
        guard ir.instances.contains(where: { $0.mos != nil || mosType(named: $0.typeName) != nil }) else { return }
        let inventory = Set(ir.nodes)
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
            guard resolved.release.level == expected.level else {
                throw .mosReleaseMismatch(instance: instance.name, expectedLevel: expected.level, actual: resolved.release)
            }
            guard resolved.polarity == expected.polarity else {
                throw .mosPolarityMismatch(instance: instance.name, expected: expected.polarity, actual: resolved.polarity)
            }
            guard instance.nodes.count == 4 else {
                throw .mosPhysicalPortCount(instance: instance.name, actual: instance.nodes.count)
            }
            guard instance.ownedNodes.isEmpty, instance.ownedBranches.isEmpty else {
                throw .unexpectedMOSStage(instance: instance.name)
            }
            for node in instance.nodes {
                guard node == ir.groundNode || inventory.contains(node) else { throw .mosNodeMissing(instance: instance.name, node: node.id) }
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
        default: return nil
        }
    }

}

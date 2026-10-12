import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceMOSContracts
import CoreSpiceParsedIR

extension NativeCircuitPreparer {
    internal func prepareMOSCircuit(_ circuit: CircuitIR, resources: any SPICESourceResourceAccounting,
        limits: SPICENativeExecutionLimits, matrixCeiling: Int, baseDimension: Int, owners: inout UniqueArray<NativePreparedMOSDevice?>) throws -> CircuitIR {
        var dimension = baseDimension
        var nodes = circuit.nodes
        var names = circuit.nodeNames
        var diagnosticNames = Set(names.values.map { $0.lowercased() })
        var nextID = circuit.nodes.reduce(0) { max($0, $1.id) }
        var instances: [Instance] = []; instances.reserveCapacity(circuit.instances.count)
        let control = NativeMOSPreparationControl(resources: resources)
        for instance in circuit.instances {
            try resources.checkCancellation()
            guard case .resolved(let resolved) = instance.mos else {
                owners.append(nil); instances.append(instance); continue
            }
            guard instance.ownedNodes.isEmpty, let mosLimits = limits.mosPreparationLimits,
                  let conditions = limits.mosPreparationConditions else {
                throw SPICENativePreparationError.mosPreparation(.invalidConditions)
            }
            let owner: NativePreparedMOSDevice
            do { owner = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved, conditions: conditions),
                    limits: mosLimits, control: control) }
            catch { throw SPICENativePreparationError.mosPreparation(error) }
            let receipt = owner.receipt
            let (nextDimension, overflow) = dimension.addingReportingOverflow(receipt.topology.auxiliaryNodeCount)
            guard !overflow, nextDimension <= matrixCeiling else { throw SPICENativePreparationError.capacityExceeded }
            dimension = nextDimension
            var auxiliary: [Node] = []; auxiliary.reserveCapacity(receipt.topology.auxiliaryNodeCount)
            for offset in 0..<receipt.topology.auxiliaryNodeCount {
                let (newID, overflow) = nextID.addingReportingOverflow(1)
                guard !overflow, newID > 0 else { throw SPICENativePreparationError.capacityExceeded }
                nextID = newID
                let name = "\(instance.name):mos_aux\(offset + 5)"
                guard diagnosticNames.insert(name.lowercased()).inserted else {
                    throw SPICENativePreparationError.mosBinding(.topologyMismatch)
                }
                let node = Node(id: nextID)
                auxiliary.append(node); nodes.append(node); names[node] = name
            }
            instances.append(Instance(name: instance.name, typeName: instance.typeName, nodes: instance.nodes,
                parameters: instance.parameters, model: instance.model, mos: .prepared(receipt),
                modelConsumption: instance.modelConsumption, ownedNodes: auxiliary, ownedBranches: instance.ownedBranches,
                referencedBranches: instance.referencedBranches, referencedNodes: instance.referencedNodes,
                opticalNodes: instance.opticalNodes))
            owners.append(consume owner)
        }
        return CircuitIR(nodes: nodes, branches: circuit.branches, instances: instances,
            groundNode: circuit.groundNode, nodeNames: names, branchNames: circuit.branchNames,
            opticalNodes: circuit.opticalNodes, opticalConnections: circuit.opticalConnections, evaluationEnvironment: circuit.evaluationEnvironment)
    }

}

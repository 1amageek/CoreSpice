import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceMOSContracts
import CoreSpiceParsedIR

extension NativeCircuitPreparer {
    internal func prepareMOSCircuit(_ circuit: CircuitIR, resources: any SPICESourceResourceAccounting,
        limits: SPICENativeExecutionLimits, owners: inout UniqueArray<NativePreparedMOSDevice?>) throws -> CircuitIR {
        var instances: [Instance] = []; instances.reserveCapacity(circuit.instances.count)
        let control = NativeMOSPreparationControl(resources: resources)
        for instance in circuit.instances {
            try resources.checkCancellation()
            guard case .resolved(let resolved) = instance.mos else {
                owners.append(nil); instances.append(instance); continue
            }
            guard instance.ownedNodes.isEmpty, instance.ownedBranches.isEmpty else {
                throw SPICENativePreparationError.mosBinding(.topologyMismatch)
            }
            guard let mosLimits = limits.mosPreparationLimits,
                  let conditions = limits.mosPreparationConditions else {
                throw SPICENativePreparationError.mosPreparation(.invalidConditions)
            }
            let owner: NativePreparedMOSDevice
            do { owner = try NativeMOSDevicePreparer().prepare(.init(resolved: resolved, conditions: conditions),
                    limits: mosLimits, control: control) }
            catch { throw SPICENativePreparationError.mosPreparation(error) }
            let receipt = owner.receipt
            instances.append(Instance(name: instance.name, typeName: instance.typeName, nodes: instance.nodes,
                parameters: instance.parameters, model: instance.model, mos: .prepared(receipt),
                diode: instance.diode, osdi: instance.osdi, modelConsumption: instance.modelConsumption, ownedNodes: instance.ownedNodes, ownedBranches: instance.ownedBranches,
                referencedBranches: instance.referencedBranches, referencedNodes: instance.referencedNodes,
                opticalNodes: instance.opticalNodes))
            owners.append(consume owner)
        }
        return CircuitIR(nodes: circuit.nodes, branches: circuit.branches, instances: instances,
            groundNode: circuit.groundNode, nodeNames: circuit.nodeNames, branchNames: circuit.branchNames,
            opticalNodes: circuit.opticalNodes, opticalConnections: circuit.opticalConnections, evaluationEnvironment: circuit.evaluationEnvironment)
    }

}

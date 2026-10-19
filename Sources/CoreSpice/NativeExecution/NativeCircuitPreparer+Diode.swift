import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceDiodeContracts
import CoreSpiceEvaluationContracts
import CoreSpiceParsedIR

extension NativeCircuitPreparer {
    internal func prepareDiodeCircuit(_ circuit: CircuitIR, resources: any SPICESourceResourceAccounting,
        limits: SPICENativeExecutionLimits, owners: inout UniqueArray<NativePreparedDiodeDevice?>) throws -> CircuitIR {
        var instances: [Instance] = []; instances.reserveCapacity(circuit.instances.count)
        owners.reserveCapacity(circuit.instances.count)
        let control = NativeDiodePreparationControl(resources: resources)
        for instance in circuit.instances {
            try resources.checkCancellation()
            guard let stage = instance.diode else { owners.append(nil); instances.append(instance); continue }
            guard case .resolved(let resolved) = stage, instance.nodes.count == 2,
                  let preparationLimits = limits.diodePreparationLimits, let analyses = limits.diodeAnalyses else {
                throw SPICENativePreparationError.diodePreparation(.invalidConditions)
            }
            let owner: NativePreparedDiodeDevice
            do {
                let environment = try EvaluationEnvironment(identity: resolved.environment)
                let input = try DiodePreparationInput(resolved: resolved, environment: environment,
                    analyses: analyses, anodeNodeID: instance.nodes[0].id, cathodeNodeID: instance.nodes[1].id)
                owner = try NativeDiodeDevicePreparer().prepare(input, limits: preparationLimits, control: control)
            } catch let error as DiodePreparationFailure { throw SPICENativePreparationError.diodePreparation(error) }
            let receipt = owner.receipt
            instances.append(Instance(name: instance.name, typeName: instance.typeName, nodes: instance.nodes,
                parameters: instance.parameters, model: instance.model, mos: instance.mos, diode: .prepared(receipt), osdi: instance.osdi,
                modelConsumption: instance.modelConsumption, ownedNodes: instance.ownedNodes,
                ownedBranches: instance.ownedBranches, referencedBranches: instance.referencedBranches,
                referencedNodes: instance.referencedNodes, opticalNodes: instance.opticalNodes))
            owners.append(consume owner)
        }
        return CircuitIR(nodes: circuit.nodes, branches: circuit.branches, instances: instances,
            groundNode: circuit.groundNode, nodeNames: circuit.nodeNames, branchNames: circuit.branchNames,
            opticalNodes: circuit.opticalNodes, opticalConnections: circuit.opticalConnections,
            evaluationEnvironment: circuit.evaluationEnvironment)
    }
}

import CoreSpiceIO
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceMOSContracts

extension SPICENativeSimulation {
    internal func validateMOSConditions(input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits) throws {
        guard limits.mosPreparationLimits != nil, let conditions = limits.mosPreparationConditions else {
            throw SPICENativePreparationError.mosPreparation(.invalidConditions)
        }
        let configuration = input.configuration
        var capabilities: MOSAnalysisCapabilities = [.dc]
        if case .transient = configuration.analysis { capabilities.insert(.transient) }
        if configuration.options.bsim4NoisePreparationRequested { capabilities.insert(.noise) }
        guard conditions.ambientKelvin == configuration.temperatureCelsius + 273.15,
              conditions.nominalKelvin == configuration.nominalTemperatureCelsius + 273.15,
              conditions.analysisCapabilities == capabilities else {
            throw SPICENativePreparationError.mosPreparation(.invalidConditions)
        }
        for instance in input.circuit.instances {
            guard case .resolved(let resolved) = instance.mos else { continue }
            if resolved.release == .bsim4_4_8_3 {
                guard let policy = configuration.options.bsim4PreparationPolicy,
                      policy.maximumStressIterations == conditions.maximumStressIterations else {
                    throw SPICENativePreparationError.mosPreparation(.invalidConditions)
                }
            }
        }
    }

    internal func prepareMOSCircuit(_ circuit: CircuitIR, input: PreparedSPICESimulation,
        limits: SPICENativeExecutionLimits, owners: inout UniqueArray<NativePreparedMOSDevice?>) throws -> CircuitIR {
        var nodes = circuit.nodes
        var names = circuit.nodeNames
        var diagnosticNames = Set(names.values.map { $0.lowercased() })
        var nextID = circuit.nodes.reduce(0) { max($0, $1.id) }
        var instances: [Instance] = []; instances.reserveCapacity(circuit.instances.count)
        let control = NativeMOSPreparationControl(resources: input.resources)
        for instance in circuit.instances {
            try input.resources.checkCancellation()
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
            opticalNodes: circuit.opticalNodes, opticalConnections: circuit.opticalConnections)
    }

    internal func encodeMOS(_ receipt: MOSPreparationReceipt, input: PreparedSPICESimulation,
                            encoding: inout SPICEPreparationEncoding) throws {
        let resolved = receipt.identity.resolved
        try encoding.field("mos-preparation.v1")
        try encodeSource(resolved.source, input: input, encoding: &encoding)
        if let source = resolved.instanceSource {
            try encoding.integer(1); try encodeSource(source, input: input, encoding: &encoding)
        } else { try encoding.integer(0) }
        try encoding.field(resolved.instance)
        try encoding.field(resolved.symbolNames[Int(resolved.selectedName.rawValue)])
        try encoding.field(resolved.polarity == .nmos ? "nmos" : "pmos")
        try encoding.field(resolved.release.rawValue); try encoding.field(resolved.release.exactVersion ?? "")
        try encoding.field(resolved.schema.release.rawValue); try encoding.integer(UInt64(resolved.schema.revision))
        try encodeParameters(resolved.modelCoefficients, symbols: resolved.symbolNames, encoding: &encoding)
        try encodeParameters(resolved.instanceParameters, symbols: resolved.symbolNames, encoding: &encoding)
        for value in [resolved.normalizedGeometry.length, resolved.normalizedGeometry.width,
                      resolved.normalizedGeometry.drainArea, resolved.normalizedGeometry.sourceArea,
                      resolved.normalizedGeometry.drainPerimeter, resolved.normalizedGeometry.sourcePerimeter,
                      resolved.selectionGeometry.length, resolved.selectionGeometry.width] {
            if let value { try encoding.integer(1); try encoding.number(value) }
            else { try encoding.integer(0) }
        }
        try encoding.number(resolved.geometryScale); try encoding.number(resolved.selectionGeometry.fingerDivisor)
        let conditions = receipt.identity.conditions
        try encoding.number(conditions.ambientKelvin); try encoding.number(conditions.nominalKelvin)
        try encoding.integer(UInt64(conditions.analysisCapabilities.rawValue))
        try encoding.integer(UInt64(conditions.maximumStressIterations))
        try encoding.field(receipt.identity.implementationIdentity)
        let topology = receipt.topology
        for slot in [topology.localNodeCount, topology.drainPrime, topology.sourcePrime, topology.gatePrime,
                     topology.gateMid, topology.bodyPrime, topology.drainBody, topology.sourceBody, topology.chargeNode] {
            try encoding.integer(UInt64(slot))
        }
    }

    private func encodeSource(_ origin: MOSSourceOccurrence, input: PreparedSPICESimulation,
                              encoding: inout SPICEPreparationEncoding) throws {
        guard let capture = origin.captureID, let occurrence = origin.occurrenceID,
              let offset = origin.statementByteOffset, let ordinal = origin.statementOrdinal,
              let source = input.sources.first(where: { $0.binding.key == capture }) else {
            throw SPICENativePreparationError.unsupportedCapability("MOS source requires captured content and exact occurrence")
        }
        try encoding.field(source.binding.reference.digest.hexadecimalValue)
        try encoding.integer(source.binding.reference.byteCount)
        try encoding.integer(occurrence); try encoding.integer(offset); try encoding.integer(ordinal)
    }

    private func encodeParameters(_ parameters: [MOSNumericParameter], symbols: [String],
                                  encoding: inout SPICEPreparationEncoding) throws {
        try encoding.integer(UInt64(parameters.count))
        for parameter in parameters.sorted(by: { symbols[Int($0.symbol.rawValue)] < symbols[Int($1.symbol.rawValue)] }) {
            try encoding.field(symbols[Int(parameter.symbol.rawValue)]); try encoding.number(parameter.value)
        }
    }
}

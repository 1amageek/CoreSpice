import CoreSpiceDiodeContracts
import CoreSpiceEvaluationContracts
import CoreSpiceIR
import CoreSpiceMOSContracts

/// Lowering-owned circuit builder using the same adapter capacity ledger as every job.
struct BoundedFrontendNetlist {
    let storage: FrontendStorage
    private var nodeMap: [String: Node] = [:]
    private var nodeNames: [Node: String] = [:]
    private var nodes: [Node] = []
    private var branches: [Branch] = []
    private var branchNames: [Branch: String] = [:]
    private var branchMap: [String: Branch] = [:]
    private var instances: [Instance] = []
    private var instanceIndices: [String: Int] = [:]
    private var references: [[String]] = []

    init(storage: FrontendStorage) throws {
        self.storage = storage
        try storage.reserve(&nodes, 1); nodes.append(.ground)
        try storage.reserve(&nodeMap, 2); nodeMap["0"] = .ground; nodeMap["gnd"] = .ground
        try storage.reserve(&nodeNames, 1); nodeNames[.ground] = "0"
        try storage.text("0"); try storage.text("gnd"); try storage.text("0")
    }
    mutating func node(_ name: String) throws -> Node {
        try storage.spend()
        guard !name.isEmpty else { throw LoweringError.invalidNode(name: name) }
        if let value = nodeMap[name] { return value }
        let value = Node(id: nodes.count)
        try storage.text(name); try storage.text(name)
        try storage.reserve(&nodeMap, nodeMap.count + 1); nodeMap[name] = value
        try storage.reserve(&nodeNames, nodeNames.count + 1); nodeNames[value] = name
        try storage.reserve(&nodes, nodes.count + 1); nodes.append(value)
        return value
    }
    mutating func branch(name: String? = nil) throws -> Branch {
        try storage.spend()
        let value = Branch(id: branches.count)
        try storage.reserve(&branches, branches.count + 1); branches.append(value)
        if let name {
            guard branchMap[name.lowercased()] == nil else { throw LoweringError.invalidComponent(name: name, reason: "Duplicate branch name") }
            try storage.text(name); try storage.text(name.lowercased())
            try storage.reserve(&branchNames, branchNames.count + 1); branchNames[value] = name
            try storage.reserve(&branchMap, branchMap.count + 1); branchMap[name.lowercased()] = value
        }
        return value
    }
    mutating func addInstance(name: String, typeName: String, nodes names: [String],
        parameters: [String: ParameterValue] = [:], model: ResolvedDeviceModel? = nil,
        mos: MOSInstanceStage? = nil, diode: DiodeInstanceStage? = nil, modelConsumption: ModelConsumption? = nil,
        ownedBranches: [Branch] = [], referencedBranchNames: [String] = [],
        referencedNodeNames: [String] = []) throws {
        try storage.spend()
        guard !name.isEmpty, instanceIndices[name] == nil else { throw NetlistError.duplicateInstanceName(name) }
        var ports: [Node] = [], readNodes: [Node] = []
        for name in names { try storage.reserve(&ports, ports.count + 1); ports.append(try node(name)) }
        for name in referencedNodeNames { try storage.reserve(&readNodes, readNodes.count + 1); readNodes.append(try node(name)) }
        for (key, value) in parameters {
            try storage.text(key)
            switch value {
            case .real(let number):
                guard number.isFinite else { throw LoweringError.invalidComponent(name: name, reason: "Nonfinite parameter") }
            case .string(let text): try storage.text(text)
            case .realVector(let vector): try storage.retain(vector)
            default: break
            }
        }
        try storage.budget.add(MOSStorageBudget.capacityBytes(parameters.capacity, of: (String, ParameterValue).self))
        try storage.text(name); try storage.text(name); try storage.text(typeName)
        try storage.retain(ownedBranches); try storage.retain(referencedBranchNames)
        for name in referencedBranchNames { try storage.text(name) }
        try storage.reserve(&instanceIndices, instanceIndices.count + 1); instanceIndices[name] = instances.count
        try storage.reserve(&instances, instances.count + 1)
        instances.append(.init(name: name, typeName: typeName, nodes: ports, parameters: parameters,
            model: model, mos: mos, diode: diode, modelConsumption: modelConsumption, ownedBranches: ownedBranches,
            referencedNodes: readNodes))
        try storage.reserve(&references, references.count + 1); references.append(referencedBranchNames)
    }
    mutating func build(environment: EvaluationEnvironmentIdentity) throws -> CircuitIR {
        for index in instances.indices {
            try storage.spend()
            var resolved: [Branch] = []
            for name in references[index] {
                guard let branch = branchMap[name.lowercased()] else {
                    throw LoweringError.invalidComponent(name: instances[index].name, reason: "No branch named '\(name)'")
                }
                try storage.reserve(&resolved, resolved.count + 1); resolved.append(branch)
            }
            let original = instances[index]
            instances[index] = .init(name: original.name, typeName: original.typeName, nodes: original.nodes,
                parameters: original.parameters, model: original.model, mos: original.mos, diode: original.diode,
                modelConsumption: original.modelConsumption, ownedNodes: original.ownedNodes,
                ownedBranches: original.ownedBranches, referencedBranches: resolved,
                referencedNodes: original.referencedNodes)
        }
        return CircuitIR(nodes: nodes, branches: branches, instances: instances,
            nodeNames: nodeNames, branchNames: branchNames, evaluationEnvironment: environment)
    }
}

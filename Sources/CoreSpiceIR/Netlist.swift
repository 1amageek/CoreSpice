/// A builder for constructing a `CircuitIR` from named nodes and device instances.
///
/// `Netlist` manages node name resolution, branch allocation, and
/// instance registration. Once all elements have been added, call
/// `build()` to produce the final `CircuitIR`.
public struct Netlist: Sendable {

    private var nextNodeID: Int = 1  // 0 is reserved for ground
    private var nextBranchID: Int = 0
    private var nextOpticalNodeID: Int = 1  // 0 is reserved for optical ground
    private var nodes: [String: Node] = ["0": .ground, "gnd": .ground]
    private var nodeNames: [Node: String] = [.ground: "0"]
    private var branchNames: [Branch: String] = [:]
    private var opticalNodeMap: [String: OpticalNode] = [:]
    private var instances: [Instance] = []
    private var referencedBranchNamesByInstance: [String: [String]] = [:]
    private var branches: [Branch] = []
    private var instanceNames: Set<String> = []

    public init() {}

    /// Resolves a node name to a `Node`, creating a new one if the name has not been seen.
    ///
    /// The names "0" and "gnd" are pre-mapped to `Node.ground`.
    @discardableResult
    public mutating func node(_ name: String) -> Node {
        if let existing = nodes[name] {
            if nodeNames[existing] == nil {
                nodeNames[existing] = name
            }
            return existing
        }
        let n = Node(id: nextNodeID)
        nextNodeID += 1
        nodes[name] = n
        nodeNames[n] = name
        return n
    }

    /// Resolves an optical node name to an `OpticalNode`, creating a new one if needed.
    ///
    /// Optical node IDs start from 1 (0 is reserved for optical ground).
    @discardableResult
    public mutating func opticalNode(_ name: String) -> OpticalNode {
        if let existing = opticalNodeMap[name] {
            return existing
        }
        let n = OpticalNode(id: nextOpticalNodeID)
        nextOpticalNodeID += 1
        opticalNodeMap[name] = n
        return n
    }

    /// Allocates a new branch variable for the MNA system.
    public mutating func branch(name: String? = nil) -> Branch {
        let b = Branch(id: nextBranchID)
        nextBranchID += 1
        branches.append(b)
        if let name {
            branchNames[b] = name
        }
        return b
    }

    /// Resolves an allocated branch by its source-level name.
    public func branch(named name: String) -> Branch? {
        branchNames.first { _, branchName in
            branchName.caseInsensitiveCompare(name) == .orderedSame
        }?.key
    }

    /// Adds a device instance to the netlist.
    ///
    /// - Parameters:
    ///   - name: Unique instance name (e.g. "R1", "V1").
    ///   - typeName: Device type identifier (e.g. "resistor", "vsource").
    ///   - nodeNames: Ordered list of node names the instance connects to.
    ///   - parameters: Parameter values keyed by parameter name.
    /// - Throws: `NetlistError.duplicateInstanceName` if the name is already in use,
    ///           or other validation errors.
    public mutating func addInstance(
        name: String,
        typeName: String,
        nodes nodeNames: [String],
        parameters: [String: ParameterValue] = [:],
        ownedBranches: [Branch] = [],
        referencedBranches: [Branch] = [],
        referencedBranchNames: [String] = [],
        referencedNodeNames: [String] = []
    ) throws {
        // Check for duplicate instance name
        guard !instanceNames.contains(name) else {
            throw NetlistError.duplicateInstanceName(name)
        }

        // Check for empty instance name
        guard !name.isEmpty else {
            throw NetlistError.invalidParameterValue(
                instance: "(unnamed)",
                parameter: "name",
                message: "Instance name cannot be empty"
            )
        }

        // Check for empty node names
        for nodeName in nodeNames {
            guard !nodeName.isEmpty else {
                throw NetlistError.invalidParameterValue(
                    instance: name,
                    parameter: "nodes",
                    message: "Node name cannot be empty"
                )
            }
        }

        // Validate parameter values
        for (key, value) in parameters {
            if case .real(let v) = value {
                guard v.isFinite else {
                    throw NetlistError.invalidParameterValue(
                        instance: name,
                        parameter: key,
                        message: "Parameter value must be finite (got \(v))"
                    )
                }
            }
        }

        instanceNames.insert(name)
        referencedBranchNamesByInstance[name] = referencedBranchNames
        let resolvedNodes = nodeNames.map { self.node($0) }
        let resolvedReferencedNodes = referencedNodeNames.map { self.node($0) }
        instances.append(
            Instance(
                name: name,
                typeName: typeName,
                nodes: resolvedNodes,
                parameters: parameters,
                ownedBranches: ownedBranches,
                referencedBranches: referencedBranches,
                referencedNodes: resolvedReferencedNodes
            )
        )
    }

    /// Adds a device instance with both electrical and optical node connections.
    ///
    /// - Parameters:
    ///   - name: Unique instance name (e.g. "LD1", "PD1").
    ///   - typeName: Device type identifier (e.g. "laser", "photodiode").
    ///   - nodeNames: Ordered list of electrical node names.
    ///   - opticalNodeNames: Ordered list of optical node names the instance connects to.
    ///     The order must match the device's optical port order.
    ///   - parameters: Parameter values keyed by parameter name.
    public mutating func addInstance(
        name: String,
        typeName: String,
        nodes nodeNames: [String],
        opticalNodes opticalNodeNames: [String],
        parameters: [String: ParameterValue] = [:],
        ownedBranches: [Branch] = [],
        referencedBranches: [Branch] = [],
        referencedBranchNames: [String] = [],
        referencedNodeNames: [String] = []
    ) throws {
        guard !instanceNames.contains(name) else {
            throw NetlistError.duplicateInstanceName(name)
        }
        guard !name.isEmpty else {
            throw NetlistError.invalidParameterValue(
                instance: "(unnamed)",
                parameter: "name",
                message: "Instance name cannot be empty"
            )
        }
        for nodeName in nodeNames {
            guard !nodeName.isEmpty else {
                throw NetlistError.invalidParameterValue(
                    instance: name,
                    parameter: "nodes",
                    message: "Node name cannot be empty"
                )
            }
        }
        for (key, value) in parameters {
            if case .real(let v) = value {
                guard v.isFinite else {
                    throw NetlistError.invalidParameterValue(
                        instance: name,
                        parameter: key,
                        message: "Parameter value must be finite (got \(v))"
                    )
                }
            }
        }

        instanceNames.insert(name)
        referencedBranchNamesByInstance[name] = referencedBranchNames
        let resolvedNodes = nodeNames.map { self.node($0) }
        let resolvedReferencedNodes = referencedNodeNames.map { self.node($0) }
        let resolvedOpticalNodes = opticalNodeNames.map { self.opticalNode($0) }
        instances.append(
            Instance(
                name: name,
                typeName: typeName,
                nodes: resolvedNodes,
                parameters: parameters,
                ownedBranches: ownedBranches,
                referencedBranches: referencedBranches,
                referencedNodes: resolvedReferencedNodes,
                opticalNodes: resolvedOpticalNodes
            )
        )
    }

    /// Builds the final `CircuitIR` from all registered nodes, branches, and instances.
    ///
    /// - Throws: `NetlistError.emptyNetlist` if no instances have been added.
    public func build() throws -> CircuitIR {
        guard !instances.isEmpty else {
            throw NetlistError.emptyNetlist
        }
        let allNodes = Array(Set(nodes.values)).sorted { $0.id < $1.id }
        let allOpticalNodes = Array(opticalNodeMap.values).sorted { $0.id < $1.id }
        let resolvedInstances = try instances.map { instance -> Instance in
            let referenceNames = referencedBranchNamesByInstance[instance.name] ?? []
            let namedReferences = try referenceNames.map { referenceName -> Branch in
                guard let branch = branch(named: referenceName) else {
                    throw NetlistError.invalidParameterValue(
                        instance: instance.name,
                        parameter: "branch_reference",
                        message: "No branch named '\(referenceName)' exists"
                    )
                }
                return branch
            }
            return Instance(
                name: instance.name,
                typeName: instance.typeName,
                nodes: instance.nodes,
                parameters: instance.parameters,
                ownedBranches: instance.ownedBranches,
                referencedBranches: instance.referencedBranches + namedReferences,
                referencedNodes: instance.referencedNodes,
                opticalNodes: instance.opticalNodes
            )
        }
        return CircuitIR(
            nodes: allNodes,
            branches: branches,
            instances: resolvedInstances,
            nodeNames: nodeNames,
            branchNames: branchNames,
            opticalNodes: allOpticalNodes
        )
    }
}

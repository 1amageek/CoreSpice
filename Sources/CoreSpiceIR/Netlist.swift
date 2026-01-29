/// A builder for constructing a `CircuitIR` from named nodes and device instances.
///
/// `Netlist` manages node name resolution, branch allocation, and
/// instance registration. Once all elements have been added, call
/// `build()` to produce the final `CircuitIR`.
public struct Netlist: Sendable {

    private var nextNodeID: Int = 1  // 0 is reserved for ground
    private var nextBranchID: Int = 0
    private var nodes: [String: Node] = ["0": .ground, "gnd": .ground]
    private var instances: [Instance] = []
    private var branches: [Branch] = []
    private var instanceNames: Set<String> = []

    public init() {}

    /// Resolves a node name to a `Node`, creating a new one if the name has not been seen.
    ///
    /// The names "0" and "gnd" are pre-mapped to `Node.ground`.
    @discardableResult
    public mutating func node(_ name: String) -> Node {
        if let existing = nodes[name] {
            return existing
        }
        let n = Node(id: nextNodeID)
        nextNodeID += 1
        nodes[name] = n
        return n
    }

    /// Allocates a new branch variable for the MNA system.
    public mutating func branch() -> Branch {
        let b = Branch(id: nextBranchID)
        nextBranchID += 1
        branches.append(b)
        return b
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
        parameters: [String: ParameterValue] = [:]
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
        let resolvedNodes = nodeNames.map { self.node($0) }
        instances.append(
            Instance(
                name: name,
                typeName: typeName,
                nodes: resolvedNodes,
                parameters: parameters
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
        return CircuitIR(
            nodes: allNodes,
            branches: branches,
            instances: instances
        )
    }
}

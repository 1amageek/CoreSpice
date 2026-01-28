/// The intermediate representation of a complete circuit.
///
/// `CircuitIR` captures all structural information needed to
/// set up and solve the MNA system: nodes, branches, device
/// instances, and the designated ground reference.
public struct CircuitIR: Sendable {

    public let nodes: [Node]
    public let branches: [Branch]
    public let instances: [Instance]
    public let groundNode: Node

    public init(
        nodes: [Node],
        branches: [Branch],
        instances: [Instance],
        groundNode: Node = .ground
    ) {
        self.nodes = nodes
        self.branches = branches
        self.instances = instances
        self.groundNode = groundNode
    }
}

/// Derived topology information for setting up the MNA matrix.
///
/// `CircuitTopology` computes the matrix dimensions and maps each
/// MNA variable (node voltage or branch current) to a row/column
/// index in the system matrix.
public struct CircuitTopology: Sendable {

    /// Number of nodes excluding ground.
    public let nodeCount: Int

    /// Number of branch current variables.
    public let branchCount: Int

    /// Total MNA matrix dimension (nodeCount + branchCount).
    public let matrixSize: Int

    /// Maps each MNA variable to its row/column index in the system matrix.
    public let variableMap: [MNAVariable: Int]

    /// Builds topology from a circuit IR.
    ///
    /// Nodes excluding ground receive indices `0 ..< nodeCount`.
    /// Branches receive indices `nodeCount ..< matrixSize`.
    public init(ir: CircuitIR) {
        let nonGroundNodes = ir.nodes.filter { $0 != ir.groundNode }
            .sorted { $0.id < $1.id }
        let sortedBranches = ir.branches.sorted { $0.id < $1.id }

        self.nodeCount = nonGroundNodes.count
        self.branchCount = sortedBranches.count
        self.matrixSize = nonGroundNodes.count + sortedBranches.count

        var map: [MNAVariable: Int] = [:]
        map.reserveCapacity(matrixSize)

        for (index, node) in nonGroundNodes.enumerated() {
            map[.nodeVoltage(node)] = index
        }

        for (index, branch) in sortedBranches.enumerated() {
            map[.branchCurrent(branch)] = nodeCount + index
        }

        self.variableMap = map
    }
}

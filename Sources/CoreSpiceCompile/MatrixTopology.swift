import CoreSpiceIR

/// Maps circuit topology to MNA matrix structure.
///
/// ``MatrixTopology`` assigns row/column indices to MNA variables
/// (node voltages and branch currents) and builds the sparsity
/// pattern by analyzing device connections.
public struct MatrixTopology: Sendable {

    /// The MNA matrix dimension (non-ground nodes + branches).
    public let dimension: Int

    /// Maps each MNA variable to its matrix row/column index.
    public let variableMap: [MNAVariable: Int]

    /// The CSR sparsity pattern of the MNA system matrix.
    public let structure: SparseStructure

    /// The underlying circuit topology from IR.
    public let circuitTopology: CircuitTopology

    /// Builds the matrix topology from a circuit IR.
    ///
    /// Non-ground nodes are assigned indices `0 ..< nodeCount`.
    /// Branch currents are assigned indices `nodeCount ..< matrixSize`.
    /// The sparsity pattern is derived from device node connections:
    /// each two-terminal device stamps a 2x2 block into the matrix.
    public init(ir: CircuitIR) {
        let topology = CircuitTopology(ir: ir)
        self.circuitTopology = topology
        self.dimension = topology.matrixSize
        self.variableMap = topology.variableMap

        // Build sparsity pattern from device connections.
        var entries: [(row: Int, col: Int)] = []

        // Ensure diagonal entries exist for all variables.
        for i in 0..<topology.matrixSize {
            entries.append((row: i, col: i))
        }

        for instance in ir.instances {
            // Collect non-ground node indices for this device.
            var nodeIndices: [Int] = []
            for node in instance.nodes {
                if node != ir.groundNode {
                    if let idx = topology.variableMap[.nodeVoltage(node)] {
                        nodeIndices.append(idx)
                    }
                }
            }

            // Each pair of connected nodes stamps a 2x2 conductance block.
            for i in nodeIndices {
                for j in nodeIndices {
                    entries.append((row: i, col: j))
                }
            }
        }

        if ir.instances.contains(where: { !$0.opticalNodes.isEmpty }) {
            let allElectricalNodeIndices = ir.nodes.compactMap { node -> Int? in
                guard node != ir.groundNode else { return nil }
                return topology.variableMap[.nodeVoltage(node)]
            }
            for row in allElectricalNodeIndices {
                for col in allElectricalNodeIndices {
                    entries.append((row: row, col: col))
                }
            }
        }

        // Add branch structure from canonical per-instance connectivity.
        // This keeps PEX-scale patterns linear in local device connectivity
        // instead of coupling every branch to every circuit variable.
        var associatedBranches: Set<Branch> = []
        for instance in ir.instances {
            let nodeIndices = instance.nodes.compactMap { node -> Int? in
                guard node != ir.groundNode else { return nil }
                return topology.variableMap[.nodeVoltage(node)]
            }
            let branches = instance.ownedBranches + instance.referencedBranches
            let branchIndices = branches.compactMap {
                topology.variableMap[.branchCurrent($0)]
            }
            associatedBranches.formUnion(instance.ownedBranches)

            for branchIndex in branchIndices {
                for nodeIndex in nodeIndices {
                    entries.append((row: branchIndex, col: nodeIndex))
                    entries.append((row: nodeIndex, col: branchIndex))
                }
            }
            for row in branchIndices {
                for col in branchIndices {
                    entries.append((row: row, col: col))
                }
            }
        }

        // Legacy programmatic IR may allocate branches without associating
        // them with an instance. Preserve correctness for that source form by
        // applying the conservative pattern only to those unassociated
        // branches. Standard lowering always emits explicit associations.
        let unassociatedBranches = ir.branches.filter {
            !associatedBranches.contains($0)
        }
        if !unassociatedBranches.isEmpty {
            let nodeIndices = ir.nodes.compactMap { node -> Int? in
                guard node != ir.groundNode else { return nil }
                return topology.variableMap[.nodeVoltage(node)]
            }
            let branchIndices = unassociatedBranches.compactMap {
                topology.variableMap[.branchCurrent($0)]
            }
            for branchIndex in branchIndices {
                for nodeIndex in nodeIndices {
                    entries.append((row: branchIndex, col: nodeIndex))
                    entries.append((row: nodeIndex, col: branchIndex))
                }
            }
            for row in branchIndices {
                for col in branchIndices {
                    entries.append((row: row, col: col))
                }
            }
        }

        self.structure = SparseStructure.uncheckedFromTriplets(
            dimension: topology.matrixSize,
            entries: entries
        )
    }

    /// Returns the matrix index for the given MNA variable, or `nil` if not found.
    public func variableIndex(for variable: MNAVariable) -> Int? {
        variableMap[variable]
    }

    /// Returns the matrix index for a node voltage, or `nil` if the node is ground.
    public func nodeIndex(_ node: Node) -> Int? {
        variableMap[.nodeVoltage(node)]
    }
}

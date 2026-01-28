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

        // Add branch-related entries.
        // For each branch, stamp coupling between the branch current row
        // and the nodes of the associated voltage source or inductor.
        for branch in ir.branches {
            if let branchIdx = topology.variableMap[.branchCurrent(branch)] {
                // The branch row/column couples with all node voltage variables.
                for node in ir.nodes where node != ir.groundNode {
                    if let nodeIdx = topology.variableMap[.nodeVoltage(node)] {
                        entries.append((row: branchIdx, col: nodeIdx))
                        entries.append((row: nodeIdx, col: branchIdx))
                    }
                }
            }
        }

        self.structure = SparseStructure.fromTriplets(
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

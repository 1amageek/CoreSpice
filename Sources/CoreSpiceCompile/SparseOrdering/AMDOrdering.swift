/// Exact active minimum-degree ordering over explicit symmetric adjacency.
/// The historical AMD name does not imply a quotient-graph approximation.
public struct AMDOrdering: Sendable {
    /// Computes a deterministic fill-reducing permutation, propagating control failures.
    public static func compute(
        structure: SparseStructure,
        control: (any LinearSolverExecutionControlling)? = nil
    ) throws -> Permutation {
        try control?.checkpoint(workUnits: 1)
        let n = structure.dimension
        let outputLease = try SparseOrderingSupport.reserve(try SparseOrderingSupport.multiply(n, 2), control: control)
        let scratchLease = try SparseOrderingSupport.reserve(n, control: control)
        var graph = try SparseOrderingGraph(dimension: n, control: control)
        for row in 0..<n {
            try control?.checkpoint(workUnits: 1)
            for index in structure.rowPointers[row]..<structure.rowPointers[row + 1] {
                try control?.checkpoint(workUnits: 1)
                let column = structure.columnIndices[index]
                if row != column {
                    try graph.insert(row: row, column: column)
                    try graph.insert(row: column, column: row)
                }
            }
        }
        var heap = try IndexedDegreeHeap(graph: graph, control: control)
        var forward = Array(repeating: 0, count: n)
        var inverse = Array(repeating: 0, count: n)
        var neighbors: [Int] = []
        neighbors.reserveCapacity(n)
        var position = 0
        while let node = try heap.pop() {
            forward[node] = position
            inverse[position] = node
            position += 1
            neighbors.removeAll(keepingCapacity: true)
            for neighbor in graph.rows[node] {
                try control?.checkpoint(workUnits: 1)
                neighbors.append(neighbor)
            }
            // Heap repair work depends on update order, even when the final
            // permutation is unchanged. Canonicalize before all graph/heap updates.
            try SparseOrderingSupport.sort(&neighbors, control: control)
            for i in neighbors.indices {
                let row = neighbors[i]
                for j in (i + 1)..<neighbors.count {
                    try graph.insert(row: row, column: neighbors[j])
                    try graph.insert(row: neighbors[j], column: row)
                }
            }
            for neighbor in neighbors {
                try control?.checkpoint(workUnits: 1)
                graph.rows[neighbor].remove(node)
                try heap.update(node: neighbor, degree: graph.rows[neighbor].count)
            }
        }
        withExtendedLifetime((scratchLease, graph, heap)) {}
        return Permutation(forward: forward, inverse: inverse, storageLease: outputLease)
    }
}

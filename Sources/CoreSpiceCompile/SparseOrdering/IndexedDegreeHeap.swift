/// Exactly one queue slot per active node; equal degrees use original node IDs.
struct IndexedDegreeHeap {
    private var nodes: [Int]
    private var positions: [Int]
    private var degrees: [Int]
    private let lease: (any Sendable)?
    private let control: (any LinearSolverExecutionControlling)?

    init(graph: SparseOrderingGraph, control: (any LinearSolverExecutionControlling)?) throws {
        self.control = control
        let n = graph.rows.count
        lease = try SparseOrderingSupport.reserve(try SparseOrderingSupport.multiply(n, 3), control: control)
        nodes = Array(0..<n)
        positions = Array(0..<n)
        degrees = Array(repeating: 0, count: n)
        for node in 0..<n {
            try control?.checkpoint(workUnits: 1)
            degrees[node] = graph.rows[node].count
        }
        if n > 1 {
            for slot in stride(from: n / 2 - 1, through: 0, by: -1) { try siftDown(slot) }
        }
    }

    mutating func pop() throws -> Int? {
        guard let first = nodes.first else { return nil }
        try control?.checkpoint(workUnits: 1)
        swap(0, nodes.count - 1)
        nodes.removeLast()
        positions[first] = -1
        if !nodes.isEmpty { try siftDown(0) }
        return first
    }

    mutating func update(node: Int, degree: Int) throws {
        try control?.checkpoint(workUnits: 1)
        let oldDegree = degrees[node]
        degrees[node] = degree
        var slot = positions[node]
        precondition(slot >= 0)
        if degree < oldDegree {
            while slot > 0 {
                try control?.checkpoint(workUnits: 1)
                let parent = (slot - 1) / 2
                guard precedes(nodes[slot], nodes[parent]) else { break }
                swap(slot, parent)
                slot = parent
            }
        } else {
            try siftDown(slot)
        }
    }

    private func precedes(_ lhs: Int, _ rhs: Int) -> Bool {
        degrees[lhs] < degrees[rhs] || (degrees[lhs] == degrees[rhs] && lhs < rhs)
    }

    private mutating func swap(_ lhs: Int, _ rhs: Int) {
        nodes.swapAt(lhs, rhs)
        positions[nodes[lhs]] = lhs
        positions[nodes[rhs]] = rhs
    }

    private mutating func siftDown(_ start: Int) throws {
        var slot = start
        while slot < nodes.count / 2 {
            try control?.checkpoint(workUnits: 1)
            var child = slot * 2 + 1
            if child + 1 < nodes.count && precedes(nodes[child + 1], nodes[child]) { child += 1 }
            guard precedes(nodes[child], nodes[slot]) else { break }
            swap(slot, child)
            slot = child
        }
    }
}

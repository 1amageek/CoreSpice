/// Run-local adjacency with admission before every opaque Set capacity expansion.
struct SparseOrderingGraph {
    var rows: [Set<Int>]
    private var capacities: [Int]
    private var leases: [(any Sendable)?]
    private let baseLease: (any Sendable)?
    private let control: (any LinearSolverExecutionControlling)?

    init(dimension: Int, control: (any LinearSolverExecutionControlling)?) throws {
        self.control = control
        let stride = MemoryLayout<Set<Int>>.stride + MemoryLayout<Int>.stride
            + MemoryLayout<(any Sendable)?>.stride
        baseLease = try SparseOrderingSupport.reserve(dimension, stride: stride, control: control)
        rows = Array(repeating: Set<Int>(), count: dimension)
        capacities = Array(repeating: 0, count: dimension)
        leases = Array(repeating: nil, count: dimension)
    }

    mutating func insert(row: Int, column: Int) throws {
        try control?.checkpoint(workUnits: 1)
        guard !rows[row].contains(column) else { return }
        if rows[row].count == capacities[row] {
            let capacity: Int
            if capacities[row] == 0 {
                capacity = 4
            } else {
                capacity = try SparseOrderingSupport.multiply(capacities[row], 2)
            }
            // Set exposes no exact allocation contract. Charge a conservative 128-byte
            // envelope per admitted element, covering hash buckets and load-factor slack.
            let replacement = try SparseOrderingSupport.reserve(capacity, stride: 128, control: control)
            let previous = leases[row]
            rows[row].reserveCapacity(capacity)
            withExtendedLifetime(previous) {}
            capacities[row] = capacity
            leases[row] = replacement
        }
        rows[row].insert(column)
    }
}

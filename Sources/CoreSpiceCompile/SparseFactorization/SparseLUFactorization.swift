/// Left-looking column LU; factors store all nonzero numeric fill, without a dense fallback.
struct SparseLUFactorization<Scalar: SparseLUScalar>: Sendable {
    private var control: (any LinearSolverExecutionControlling)?
    private var structure: SparseStructure?
    private var orderingMode = false
    private var ordering = Permutation.identity(size: 0)
    private var n = 0
    private var ready = false
    private var ap: [Int] = [], ai: [Int] = [], axIndex: [Int] = []
    private var leaders: [Int] = [], leaderCount = 0
    private var pinv: [Int] = [], marks: [Int] = []
    private var dfsRows: [Int] = [], dfsNext: [Int] = [], post: [Int] = []
    private var x: [Scalar] = []
    private var lp: [Int] = [], li: [Int] = [], lx: [Scalar] = [], lnz = 0
    private var up: [Int] = [], ui: [Int] = [], ux: [Scalar] = [], unz = 0
    private var diagonal: [Int] = []
    private var leases: [any Sendable] = []
    private var leaseBytes = 0, coexistingBytes = 0, peakBytes = 0
    private var baseBytes = 20 * MemoryLayout<Array<Int>>.stride
    private var factorBytes = 0
    private var lastWork = 0, lastCharge = 0, swaps = 0
    private var analyses = 0, factorizations = 0, allocations = 0

    var statistics: SparseFactorizationStatistics {
        .init(dimension: n, inputNonZeroCount: structure?.nonZeroCount ?? 0,
            lowerNonZeroCount: lnz, upperNonZeroCount: unz, factorCapacity: li.count + ui.count,
            managedBytes: baseBytes + factorBytes, peakManagedBytes: peakBytes,
            workUnits: lastWork, chargedWorkUnits: lastCharge, pivotInterchanges: swaps,
            structuralAnalyses: analyses, numericFactorizations: factorizations, bufferAllocations: allocations)
    }

    mutating func configureExecution(_ control: (any LinearSolverExecutionControlling)?) throws {
        self.control = control
    }

    mutating func factorize(structure input: SparseStructure, values: borrowing [Scalar],
                           useAMDOrdering: Bool) throws {
        ready = false
        try control?.checkpoint(workUnits: 0)
        guard values.count == input.nonZeroCount else {
            throw CompileError.vectorDimensionMismatch(vector: "matrixValues", expected: input.nonZeroCount, actual: values.count)
        }
        var meter = SparseLUWorkMeter(control: control)
        defer { lastWork = meter.work; lastCharge = meter.charged }
        for i in values.indices {
            try meter.spend()
            guard values[i].luIsFinite else { throw SparseSolverError.nonFiniteMatrixValue(index: i) }
        }
        // Admission precedes possible COW detachment. Copies keep the old buffers and leases.
        let previous = leases
        let oldBytes = leaseBytes
        let payload = try Self.add(baseBytes, factorBytes)
        let replacement = try control?.reserveStorage(byteCount: payload)
        leases = []
        if let replacement { leases.append(replacement) }
        leaseBytes = payload
        coexistingBytes = oldBytes
        peakBytes = max(peakBytes, try Self.add(oldBytes, payload))
        defer { coexistingBytes = 0; withExtendedLifetime(previous) {} }
        if structure != input || orderingMode != useAMDOrdering {
            // A refused partial rebuild must never match the previous structure on retry.
            structure = nil
            try prepare(input, useAMDOrdering: useAMDOrdering, meter: &meter)
        }
        lnz = 0; unz = 0; swaps = 0
        for i in 0..<n { try meter.spend(); pinv[i] = -1; marks[i] = -1 }
        for k in 0..<n {
            try meter.spend()
            lp[k] = lnz; up[k] = unz
            let col = ordering.inverse[k]
            let count = try reach(column: col, generation: k, meter: &meter)
            for p in 0..<count { try meter.spend(); x[post[p]] = .luZero }
            for p in ap[col]..<ap[col + 1] {
                try meter.spend()
                x[ai[p]] = values[axIndex[p]]
            }
            // Reverse graph postorder updates a pivot before its descendant rows.
            for p in (0..<count).reversed() {
                try meter.spend()
                let row = post[p], j = pinv[row]
                guard j >= 0 else { continue }
                let value = x[row]
                for q in lp[j]..<lp[j + 1] {
                    try meter.spend()
                    let target = li[q]
                    let updated = Scalar.luSubtractProduct(x[target], lx[q], value)
                    guard updated.luIsFinite else { throw SparseSolverError.nonFiniteArithmetic }
                    x[target] = updated
                }
            }
            var pivot = -1
            var maximum = 0.0
            for p in 0..<count {
                try meter.spend()
                let row = post[p], value = x[row]
                guard value.luIsFinite else { throw SparseSolverError.nonFiniteArithmetic }
                if pinv[row] < 0 {
                    let magnitude = value.luMagnitude
                    if magnitude > maximum || (magnitude == maximum && magnitude > 0 && row < pivot) {
                        maximum = magnitude; pivot = row
                    }
                } else if value != .luZero {
                    try appendUpper(row: pinv[row], value: value, meter: &meter)
                }
            }
            guard pivot >= 0, maximum > 0 else { throw CompileError.singularMatrix }
            if pinv[col] < 0, marks[col] == k, x[col].luMagnitude >= maximum { pivot = col }
            if pivot != col { swaps += 1 }
            let pivotValue = x[pivot]
            diagonal[k] = unz
            try appendUpper(row: k, value: pivotValue, meter: &meter)
            pinv[pivot] = k
            for p in 0..<count {
                try meter.spend()
                let row = post[p]
                guard pinv[row] < 0, x[row] != .luZero else { continue }
                let value = Scalar.luDivide(x[row], pivotValue)
                guard value.luIsFinite else { throw SparseSolverError.nonFiniteArithmetic }
                if value != .luZero { try appendLower(row: row, value: value, meter: &meter) }
            }
            lp[k + 1] = lnz; up[k + 1] = unz
        }
        for p in 0..<lnz { try meter.spend(); li[p] = pinv[li[p]] }
        try control?.checkpoint(workUnits: 0)
        factorizations = try Self.add(factorizations, 1)
        ready = true
    }

    /// Factors remain immutable; the caller-owned output is the only solve work vector.
    func solve(rhs: [Scalar], into result: inout [Scalar]) throws {
        guard ready else { throw CompileError.singularMatrix }
        guard rhs.count == n else {
            throw CompileError.vectorDimensionMismatch(vector: "rhs", expected: n, actual: rhs.count)
        }
        guard result.count == n else {
            throw CompileError.vectorDimensionMismatch(vector: "result", expected: n, actual: result.count)
        }
        try control?.checkpoint(workUnits: 0)
        var meter = SparseLUWorkMeter(control: control)
        for row in 0..<n {
            try meter.spend()
            guard rhs[row].luIsFinite else { throw SparseSolverError.nonFiniteRHSValue(index: row) }
            result[pinv[row]] = rhs[row]
        }
        for col in 0..<n {
            try meter.spend()
            let value = result[col]
            for p in lp[col]..<lp[col + 1] {
                try meter.spend()
                let row = li[p]
                let value = Scalar.luSubtractProduct(result[row], lx[p], value)
                guard value.luIsFinite else { throw SparseSolverError.nonFiniteArithmetic }
                result[row] = value
            }
        }
        for col in (0..<n).reversed() {
            try meter.spend()
            let d = diagonal[col]
            let value = Scalar.luDivide(result[col], ux[d])
            guard value.luIsFinite else { throw SparseSolverError.nonFiniteArithmetic }
            result[col] = value
            for p in up[col]..<d {
                try meter.spend()
                let row = ui[p]
                let updated = Scalar.luSubtractProduct(result[row], ux[p], value)
                guard updated.luIsFinite else { throw SparseSolverError.nonFiniteArithmetic }
                result[row] = updated
            }
        }
        for p in 0..<leaderCount {
            let leader = leaders[p]
            var current = leader, carried = result[leader]
            repeat {
                try meter.spend()
                let target = ordering.inverse[current], next = result[target]
                result[target] = carried; carried = next; current = target
            } while current != leader
        }
        try control?.checkpoint(workUnits: 0)
    }

    func solve(rhs: [Scalar]) throws -> [Scalar] {
        guard ready else { throw CompileError.singularMatrix }
        guard rhs.count == n else {
            throw CompileError.vectorDimensionMismatch(vector: "rhs", expected: n, actual: rhs.count)
        }
        let lease = try control?.reserveStorage(byteCount: Self.multiply(n, MemoryLayout<Scalar>.stride))
        defer { withExtendedLifetime(lease) {} }
        var result = Array(repeating: Scalar.luZero, count: n)
        try solve(rhs: rhs, into: &result)
        return result
    }

    private mutating func prepare(_ input: SparseStructure, useAMDOrdering: Bool,
                                  meter: inout SparseLUWorkMeter) throws {
        let size = input.dimension, nnz = input.nonZeroCount
        let indices = try Self.add(Self.add(Self.multiply(size + 1, 3), Self.multiply(nnz, 2)), Self.multiply(size, 9))
        let bytes = try Self.add(Self.multiply(indices, MemoryLayout<Int>.stride),
            Self.add(Self.multiply(size, MemoryLayout<Scalar>.stride), 20 * MemoryLayout<Array<Int>>.stride))
        _ = try Self.add(bytes, factorBytes)
        try reserve(bytes)
        let permutation = useAMDOrdering
            ? try AMDOrdering.compute(structure: input, control: control)
            : Permutation.identity(size: size)
        // Array initialization is a single library primitive, admitted before allocation.
        // Explicit traversal below polls independently of this precharged allocation work.
        try meter.spend(try Self.add(indices, size))
        ap = Array(repeating: 0, count: size + 1)
        ai = Array(repeating: 0, count: nnz); axIndex = Array(repeating: 0, count: nnz)
        leaders = Array(repeating: 0, count: size); pinv = Array(repeating: -1, count: size)
        marks = Array(repeating: 0, count: size); dfsRows = Array(repeating: 0, count: size)
        dfsNext = Array(repeating: 0, count: size); post = Array(repeating: 0, count: size)
        x = Array(repeating: Scalar.luZero, count: size)
        lp = Array(repeating: 0, count: size + 1); up = Array(repeating: 0, count: size + 1)
        diagonal = Array(repeating: 0, count: size)
        // Keep retained storage and its admission estimate consistent if preparation is interrupted.
        ordering = permutation; baseBytes = bytes
        allocations = try Self.add(allocations, 13)
        try control?.checkpoint(workUnits: 0)
        for col in input.columnIndices { try meter.spend(); ap[col + 1] += 1 }
        for col in 0..<size { try meter.spend(); ap[col + 1] += ap[col]; dfsNext[col] = ap[col] }
        for row in 0..<size {
            try meter.spend()
            for p in input.rowPointers[row]..<input.rowPointers[row + 1] {
                try meter.spend()
                let col = input.columnIndices[p], destination = dfsNext[col]
                ai[destination] = row; axIndex[destination] = p; dfsNext[col] += 1
            }
        }
        leaderCount = 0
        for start in 0..<size {
            try meter.spend()
            guard marks[start] == 0 else { continue }
            var current = start
            if ordering.inverse[start] != start { leaders[leaderCount] = start; leaderCount += 1 }
            repeat {
                try meter.spend()
                marks[current] = 1; current = ordering.inverse[current]
            } while current != start
        }
        n = size; structure = input; orderingMode = useAMDOrdering
        analyses = try Self.add(analyses, 1)
    }

    private mutating func reach(column: Int, generation: Int, meter: inout SparseLUWorkMeter) throws -> Int {
        var count = 0
        for p in ap[column]..<ap[column + 1] {
            try meter.spend()
            let start = ai[p]
            guard marks[start] != generation else { continue }
            var depth = 0
            dfsRows[0] = start; marks[start] = generation
            let pivot = pinv[start]
            dfsNext[0] = pivot < 0 ? 0 : lp[pivot]
            while depth >= 0 {
                try meter.spend()
                let row = dfsRows[depth], pivot = pinv[row]
                let end = pivot < 0 ? 0 : lp[pivot + 1]
                var next = dfsNext[depth]
                while next < end && marks[li[next]] == generation { try meter.spend(); next += 1 }
                if next < end {
                    dfsNext[depth] = next + 1
                    let child = li[next]
                    depth += 1; dfsRows[depth] = child; marks[child] = generation
                    let childPivot = pinv[child]
                    dfsNext[depth] = childPivot < 0 ? 0 : lp[childPivot]
                } else {
                    post[count] = row; count += 1; depth -= 1
                }
            }
        }
        return count
    }

    private mutating func appendLower(row: Int, value: Scalar, meter: inout SparseLUWorkMeter) throws {
        try grow(lower: true, required: Self.add(lnz, 1), meter: &meter)
        li[lnz] = row; lx[lnz] = value; lnz += 1
    }
    private mutating func appendUpper(row: Int, value: Scalar, meter: inout SparseLUWorkMeter) throws {
        try grow(lower: false, required: Self.add(unz, 1), meter: &meter)
        ui[unz] = row; ux[unz] = value; unz += 1
    }
    private mutating func grow(lower: Bool, required: Int, meter: inout SparseLUWorkMeter) throws {
        let old = lower ? li.count : ui.count
        guard required > old else { return }
        let capacity = max(required, old == 0 ? max(1, structure?.nonZeroCount ?? 0) : try Self.multiply(old, 2))
        let stride = MemoryLayout<Int>.stride + MemoryLayout<Scalar>.stride
        let bytes = try Self.multiply(capacity, stride)
        let updated = try Self.add(factorBytes - Self.multiply(old, stride), bytes)
        _ = try Self.add(baseBytes, updated)
        try reserve(bytes)
        let used = lower ? lnz : unz
        try meter.spend(capacity)
        var rows = Array(repeating: 0, count: capacity)
        var values = Array(repeating: Scalar.luZero, count: capacity)
        try control?.checkpoint(workUnits: 0)
        if lower {
            for p in 0..<used { try meter.spend(); rows[p] = li[p]; values[p] = lx[p] }
            li = rows; lx = values
        } else {
            for p in 0..<used { try meter.spend(); rows[p] = ui[p]; values[p] = ux[p] }
            ui = rows; ux = values
        }
        factorBytes = updated; allocations = try Self.add(allocations, 2)
    }
    private mutating func reserve(_ bytes: Int) throws {
        let total = try Self.add(leaseBytes, bytes), peak = try Self.add(coexistingBytes, total)
        try control?.checkpoint(workUnits: 0)
        if let lease = try control?.reserveStorage(byteCount: bytes) { leases.append(lease) }
        leaseBytes = total; peakBytes = max(peakBytes, peak)
    }
    private static func add(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw SparseSolverError.capacityOverflow }; return value
    }
    private static func multiply(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw SparseSolverError.capacityOverflow }; return value
    }
}

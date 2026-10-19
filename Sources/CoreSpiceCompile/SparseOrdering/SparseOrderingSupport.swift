enum SparseOrderingSupport {
    static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw SparseOrderingError.capacityOverflow }
        return value
    }

    static func multiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw SparseOrderingError.capacityOverflow }
        return value
    }

    static func reserve(_ count: Int, stride: Int = MemoryLayout<Int>.stride,
                        control: (any LinearSolverExecutionControlling)?) throws -> (any Sendable)? {
        try control?.reserveStorage(byteCount: multiply(count, stride))
    }

    // Iterative heapsort keeps cancellation checkpoints inside sorting work.
    static func sort(_ values: inout [Int], control: (any LinearSolverExecutionControlling)?) throws {
        guard values.count > 1 else { return }
        func sift(_ values: inout [Int], _ start: Int, _ end: Int) throws {
            var parent = start
            // Fixed-height admission makes charged work independent of the
            // incoming Set enumeration, while checking cancellation at each step.
            let height = Int.bitWidth - end.leadingZeroBitCount
            var active = true
            for _ in 0..<height {
                try control?.checkpoint(workUnits: 1)
                guard active, parent < end / 2 else { active = false; continue }
                var child = parent * 2 + 1
                if child + 1 < end && values[child] < values[child + 1] { child += 1 }
                if values[parent] >= values[child] { active = false; continue }
                values.swapAt(parent, child)
                parent = child
            }
        }
        for index in stride(from: values.count / 2 - 1, through: 0, by: -1) {
            try sift(&values, index, values.count)
        }
        for end in stride(from: values.count - 1, through: 1, by: -1) {
            try control?.checkpoint(workUnits: 1)
            values.swapAt(0, end)
            try sift(&values, 0, end)
        }
    }
}

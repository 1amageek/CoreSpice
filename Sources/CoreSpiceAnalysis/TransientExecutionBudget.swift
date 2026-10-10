import Synchronization

/// One run retains this owner; no callback, device operation or I/O executes under its lock.
package final class TransientExecutionBudget: Sendable {
    private struct State: Sendable {
        var acceptedSteps = 0
        var rejectedSteps = 0
        var solveAttempts = 0
        var newtonIterations = 0
        var savedScalars = 0
        var workUnits = 0
    }
    private let state = Mutex(State())
    let limits: TransientExecutionLimits
    let dimension: Int
    private let iterationWork: Int

    package init(limits: TransientExecutionLimits, dimension: Int, nonZeroCount: Int, deviceCount: Int) throws {
        try limits.validate()
        try Self.admit(dimension, limit: limits.maximumMatrixDimension, resource: "matrixDimension")
        guard dimension > 0, nonZeroCount >= 0, deviceCount >= 0 else {
            throw AnalysisError.invalidConfiguration("Transient matrix dimension must be positive")
        }
        let squared = try Self.multiply(dimension, dimension, "matrix square")
        // Existing SparseLU can retain dense LU and both sparse factors; indices and values are bounded by n*n.
        _ = try Self.multiply(squared, 3 * (MemoryLayout<Double>.stride + MemoryLayout<Int>.stride), "factor byte envelope")
        let cubic = try Self.multiply(squared, dimension, "matrix cubic work")
        var work = cubic
        work = try Self.add(work, Self.multiply(nonZeroCount, 2, "matrix stamp work"), "iteration work")
        work = try Self.add(work, Self.multiply(deviceCount, 2, "device stamp work"), "iteration work")
        work = try Self.add(work, Self.multiply(dimension, 8, "vector work"), "iteration work")
        try Self.admit(work, limit: limits.maximumWorkUnits, resource: "workUnits")
        _ = try Self.multiply(dimension + 1, MemoryLayout<Double>.stride, "output point bytes")
        self.limits = limits
        self.dimension = dimension
        self.iterationWork = work
    }

    func beginSolve() throws {
        try state.withLock { state in
            let count = try Self.add(state.solveAttempts, 1, "solveAttempts")
            try Self.admit(count, limit: limits.maximumSolveAttempts, resource: "solveAttempts")
            state.solveAttempts = count
        }
    }

    func beginIteration() throws {
        try state.withLock { state in
            let count = try Self.add(state.newtonIterations, 1, "newtonIterations")
            let work = try Self.add(state.workUnits, iterationWork, "workUnits")
            try Self.admit(count, limit: limits.maximumNewtonIterations, resource: "newtonIterations")
            try Self.admit(work, limit: limits.maximumWorkUnits, resource: "workUnits")
            state.newtonIterations = count
            state.workUnits = work
        }
    }

    /// Charges one linear solve with the same dense-work envelope used by Newton.
    /// Complex arithmetic is bounded by four real envelopes; augmented pencils supply their dimension.
    func beginLinearSolve(dimension requestedDimension: Int? = nil, complex: Bool = false) throws {
        let size = requestedDimension ?? dimension
        guard size > 0 else { throw AnalysisError.invalidConfiguration("Linear solve dimension must be positive") }
        try Self.admit(size, limit: limits.maximumMatrixDimension, resource: "matrixDimension")
        let square = try Self.multiply(size, size, "linear matrix square")
        let cubic = try Self.multiply(square, size, "linear matrix cubic work")
        let baseCubic = try Self.multiply(Self.multiply(dimension, dimension, "base matrix square"), dimension, "base matrix cubic work")
        let overhead = iterationWork - baseCubic
        let expandedVectors = try Self.multiply(max(0, size - dimension), 8, "augmented vector work")
        let realWork = try Self.add(Self.add(cubic, overhead, "linear work"), expandedVectors, "linear work")
        let work = try Self.multiply(realWork, complex ? 4 : 1, "linear arithmetic work")
        try state.withLock { state in
            let attempts = try Self.add(state.solveAttempts, 1, "solveAttempts")
            let totalWork = try Self.add(state.workUnits, work, "workUnits")
            try Self.admit(attempts, limit: limits.maximumSolveAttempts, resource: "solveAttempts")
            try Self.admit(totalWork, limit: limits.maximumWorkUnits, resource: "workUnits")
            state.solveAttempts = attempts
            state.workUnits = totalWork
        }
    }

    func chargeWork(_ units: Int) throws {
        guard units >= 0 else { throw TransientExecutionError.invalidLimit(name: "workUnits", value: units) }
        try state.withLock { state in
            let total = try Self.add(state.workUnits, units, "workUnits")
            try Self.admit(total, limit: limits.maximumWorkUnits, resource: "workUnits")
            state.workUnits = total
        }
    }

    func admitSavedScalars(_ count: Int) throws {
        guard count >= 0 else { throw TransientExecutionError.invalidLimit(name: "savedScalars", value: count) }
        try state.withLock { state in
            let total = try Self.add(state.savedScalars, count, "savedScalars")
            try Self.admit(total, limit: limits.maximumSavedScalars, resource: "savedScalars")
            _ = try Self.multiply(total, MemoryLayout<Double>.stride, "saved output bytes")
            state.savedScalars = total
        }
    }

    package func admitSavedPoint(accepted: Bool) throws {
        try state.withLock { state in
            let steps = try Self.add(state.acceptedSteps, accepted ? 1 : 0, "acceptedSteps")
            let scalars = try Self.add(state.savedScalars, dimension + 1, "savedScalars")
            try Self.admit(steps, limit: limits.maximumAcceptedSteps, resource: "acceptedSteps")
            try Self.admit(scalars, limit: limits.maximumSavedScalars, resource: "savedScalars")
            _ = try Self.multiply(scalars, MemoryLayout<Double>.stride, "saved output bytes")
            state.acceptedSteps = steps
            state.savedScalars = scalars
        }
    }

    func rejectStep() throws {
        try state.withLock { $0.rejectedSteps = try Self.add($0.rejectedSteps, 1, "rejectedSteps") }
    }

    package var statistics: TransientExecutionStatistics {
        state.withLock { TransientExecutionStatistics(acceptedSteps: $0.acceptedSteps,
            rejectedSteps: $0.rejectedSteps, solveAttempts: $0.solveAttempts,
            newtonIterations: $0.newtonIterations, savedScalars: $0.savedScalars,
            workUnits: $0.workUnits, matrixDimension: dimension) }
    }

    static func add(_ a: Int, _ b: Int, _ operation: String) throws -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw TransientExecutionError.arithmeticOverflow(operation) }
        return result
    }

    static func multiply(_ a: Int, _ b: Int, _ operation: String) throws -> Int {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw TransientExecutionError.arithmeticOverflow(operation) }
        return result
    }

    static func admit(_ requested: Int, limit: Int, resource: String) throws {
        guard requested <= limit else {
            throw TransientExecutionError.limitExceeded(resource: resource, limit: limit, requested: requested)
        }
    }
}

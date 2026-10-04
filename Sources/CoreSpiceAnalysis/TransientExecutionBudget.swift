import Synchronization

/// One run retains this owner; no callback, device operation or I/O executes under its lock.
final class TransientExecutionBudget: Sendable {
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

    init(limits: TransientExecutionLimits, dimension: Int, nonZeroCount: Int, deviceCount: Int) throws {
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

    func admitSavedPoint(accepted: Bool) throws {
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

    var statistics: TransientExecutionStatistics {
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

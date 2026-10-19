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
        var maximumMatrixDimension = 0
    }
    private final class CounterOwner: Sendable {
        let state = Mutex(State())
    }
    private let counters: CounterOwner
    let limits: TransientExecutionLimits
    let dimension: Int
    private let iterationWork: Int
    private let invocationResources: AnalysisExecutionResources?

    package init(limits: TransientExecutionLimits, dimension: Int, nonZeroCount: Int, deviceCount: Int,
                 invocationResources: AnalysisExecutionResources? = nil) throws {
        let work = try Self.validateLayout(limits: limits, dimension: dimension,
            nonZeroCount: nonZeroCount, deviceCount: deviceCount)
        self.counters = CounterOwner()
        self.limits = limits
        self.dimension = dimension
        self.iterationWork = work
        self.invocationResources = invocationResources
    }

    /// Uses the actual rebuilt graph while retaining the same cumulative run counters and limits.
    func rebound(dimension: Int, nonZeroCount: Int, deviceCount: Int) throws -> TransientExecutionBudget {
        let work = try Self.validateLayout(limits: limits, dimension: dimension,
            nonZeroCount: nonZeroCount, deviceCount: deviceCount)
        return TransientExecutionBudget(counters: counters, limits: limits,
            dimension: dimension, iterationWork: work, invocationResources: invocationResources)
    }

    private init(counters: CounterOwner, limits: TransientExecutionLimits,
                 dimension: Int, iterationWork: Int, invocationResources: AnalysisExecutionResources?) {
        self.counters = counters
        self.limits = limits
        self.dimension = dimension
        self.iterationWork = iterationWork
        self.invocationResources = invocationResources
    }

    private static func validateLayout(limits: TransientExecutionLimits, dimension: Int,
                                       nonZeroCount: Int, deviceCount: Int) throws -> Int {
        try limits.validate()
        try Self.admit(dimension, limit: limits.maximumMatrixDimension, resource: "matrixDimension")
        guard dimension > 0, nonZeroCount >= 0, deviceCount >= 0 else {
            throw AnalysisError.invalidConfiguration("Transient matrix dimension must be positive")
        }
        // Sparse kernels admit actual graph, factor and substitution work themselves.
        var work = try Self.multiply(nonZeroCount, 2, "matrix stamp work")
        work = try Self.add(work, Self.multiply(deviceCount, 2, "device stamp work"), "iteration work")
        work = try Self.add(work, Self.multiply(dimension, 8, "vector work"), "iteration work")
        try Self.admit(work, limit: limits.maximumWorkUnits, resource: "workUnits")
        _ = try Self.multiply(Self.add(dimension, 1, "output point scalars"), MemoryLayout<Double>.stride, "output point bytes")
        return work
    }

    func beginSolve() throws {
        try counters.state.withLock { state in
            let count = try Self.add(state.solveAttempts, 1, "solveAttempts")
            try Self.admit(count, limit: limits.maximumSolveAttempts, resource: "solveAttempts")
            try invocationResources?.admit(solveAttempts: 1, dimension: dimension)
            state.solveAttempts = count
            state.maximumMatrixDimension = max(state.maximumMatrixDimension, dimension)
        }
    }

    func beginIteration() throws {
        try counters.state.withLock { state in
            let count = try Self.add(state.newtonIterations, 1, "newtonIterations")
            let work = try Self.add(state.workUnits, iterationWork, "workUnits")
            try Self.admit(count, limit: limits.maximumNewtonIterations, resource: "newtonIterations")
            try Self.admit(work, limit: limits.maximumWorkUnits, resource: "workUnits")
            try invocationResources?.admit(newtonIterations: 1, workUnits: iterationWork, dimension: dimension)
            state.newtonIterations = count
            state.maximumMatrixDimension = max(state.maximumMatrixDimension, dimension)
            state.workUnits = work
        }
    }

    /// Admits stamping and vectors; controlled sparse kernels charge their actual work.
    func beginLinearSolve(dimension requestedDimension: Int? = nil, complex: Bool = false) throws {
        let size = requestedDimension ?? dimension
        guard size > 0 else { throw AnalysisError.invalidConfiguration("Linear solve dimension must be positive") }
        try Self.admit(size, limit: limits.maximumMatrixDimension, resource: "matrixDimension")
        let expandedVectors = try Self.multiply(max(0, size - dimension), 8, "augmented vector work")
        let work = try Self.multiply(Self.add(iterationWork, expandedVectors, "linear work"),
            complex ? 4 : 1, "linear arithmetic work")
        try admitLinearAttempt(work: work, admittedDimension: size)
    }

    /// Stored-factor RHS reuse charges vectors here and substitutions in the kernel.
    func beginRefinementSolve(complex: Bool = false) throws {
        let work = try Self.multiply(dimension, complex ? 64 : 16, "refinement vector work")
        try admitLinearAttempt(work: work)
    }

    /// Dense pencil/eigen algorithms retain a separate explicit cubic envelope.
    func beginDenseLinearSolve(dimension requestedDimension: Int? = nil) throws {
        let size = requestedDimension ?? dimension
        guard size > 0 else { throw AnalysisError.invalidConfiguration("Dense solve dimension must be positive") }
        try Self.admit(size, limit: limits.maximumMatrixDimension, resource: "matrixDimension")
        let square = try Self.multiply(size, size, "dense matrix square")
        let cubic = try Self.multiply(square, size, "dense matrix cubic work")
        try admitLinearAttempt(work: Self.add(cubic, iterationWork, "dense linear work"), admittedDimension: size)
    }

    private func admitLinearAttempt(work: Int, admittedDimension: Int? = nil) throws {
        let size = admittedDimension ?? dimension
        try counters.state.withLock { state in
            let attempts = try Self.add(state.solveAttempts, 1, "solveAttempts")
            let total = try Self.add(state.workUnits, work, "workUnits")
            try Self.admit(attempts, limit: limits.maximumSolveAttempts, resource: "solveAttempts")
            try Self.admit(total, limit: limits.maximumWorkUnits, resource: "workUnits")
            try invocationResources?.admit(solveAttempts: 1, workUnits: work, dimension: size)
            state.solveAttempts = attempts
            state.maximumMatrixDimension = max(state.maximumMatrixDimension, size)
            state.workUnits = total
        }
    }

    /// Weighted loop envelope for accurate residual evaluation and the row-quality scan.
    func chargeAccurateResidual(nonZeroCount: Int) throws {
        let work = try Self.add(Self.multiply(nonZeroCount, 40, "accurate residual terms"),
            Self.multiply(dimension, 48, "accurate residual rows"), "accurate residual work")
        try chargeWork(work)
    }

    package func chargeWork(_ units: Int) throws {
        guard units >= 0 else { throw TransientExecutionError.invalidLimit(name: "workUnits", value: units) }
        try counters.state.withLock { state in
            let total = try Self.add(state.workUnits, units, "workUnits")
            try Self.admit(total, limit: limits.maximumWorkUnits, resource: "workUnits")
            try invocationResources?.admit(workUnits: units, dimension: dimension)
            state.workUnits = total
        }
    }

    func admitSavedScalars(_ count: Int) throws {
        guard count >= 0 else { throw TransientExecutionError.invalidLimit(name: "savedScalars", value: count) }
        try counters.state.withLock { state in
            let total = try Self.add(state.savedScalars, count, "savedScalars")
            try Self.admit(total, limit: limits.maximumSavedScalars, resource: "savedScalars")
            _ = try Self.multiply(total, MemoryLayout<Double>.stride, "saved output bytes")
            state.savedScalars = total
        }
    }

    package func admitSavedPoint(accepted: Bool) throws {
        try counters.state.withLock { state in
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
        try counters.state.withLock { $0.rejectedSteps = try Self.add($0.rejectedSteps, 1, "rejectedSteps") }
    }

    package var statistics: TransientExecutionStatistics {
        counters.state.withLock { TransientExecutionStatistics(acceptedSteps: $0.acceptedSteps,
            rejectedSteps: $0.rejectedSteps, solveAttempts: $0.solveAttempts,
            newtonIterations: $0.newtonIterations, savedScalars: $0.savedScalars,
            workUnits: $0.workUnits, matrixDimension: max(dimension, $0.maximumMatrixDimension)) }
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

import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import Foundation

/// Fixed-bias multiport analysis using existing independent voltage-source boundaries.
public struct NetworkParameterAnalysis: Analysis, Sendable {
    public typealias Result = NetworkParameterResult
    package var executionBudget: TransientExecutionBudget?
    package var resultStorage: (any AnalysisResultStorageAccounting)?
    public let frequencies: [Double]
    public let ports: [NetworkPort]
    public let limits: NetworkParameterLimits
    public let dcConfig: ConvergenceConfig
    public let nodeInitialGuess: [Node: Double]
    public let equationPolicy: DCEquationPolicy?
    public let physicalResidualValidator: (any DCPhysicalResidualValidating)?
    public let completionFinalizer: (any AnalysisCompletionFinalizing)?

    public init(frequencies: [Double], ports: [NetworkPort], limits: NetworkParameterLimits,
                dcConfig: ConvergenceConfig = ConvergenceConfig(), nodeInitialGuess: [Node: Double] = [:],
                equationPolicy: DCEquationPolicy? = nil,
                physicalResidualValidator: (any DCPhysicalResidualValidating)? = nil,
                completionFinalizer: (any AnalysisCompletionFinalizing)? = nil) {
        self.frequencies = frequencies; self.ports = ports; self.limits = limits
        self.dcConfig = dcConfig; self.nodeInitialGuess = nodeInitialGuess
        self.equationPolicy = equationPolicy; self.physicalResidualValidator = physicalResidualValidator
        self.completionFinalizer = completionFinalizer
    }

    public func run(plan: ExecutionPlan, devices: [any BoundDevice], solver: any LinearSolver,
                    observer: EventDispatcher?, cancellation: CancellationToken) async throws -> NetworkParameterResult {
        try limits.validate()
        guard !ports.isEmpty, ports.count <= limits.maximumPorts,
              !frequencies.isEmpty, frequencies.count <= limits.maximumFrequencyPoints else {
            throw NetworkParameterError.invalidConfiguration("Network port or frequency count exceeds caller limits")
        }
        for (index, frequency) in frequencies.enumerated() {
            guard frequency.isFinite, frequency > 0, (2 * Double.pi * frequency).isFinite,
                  index == 0 || frequency > frequencies[index - 1] else {
                throw NetworkParameterError.invalidConfiguration("Network frequencies must be finite, positive and strictly increasing")
            }
        }
        if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
        try PreparedCircuit.validate(plan: plan, devices: devices)
        guard plan.opticalNetwork == nil, !devices.contains(where: { $0 is any OptoelectronicDevice }) else {
            throw NetworkParameterError.invalidConfiguration("Mixed optical network parameters are unsupported")
        }
        let dim = plan.topology.dimension
        let n = ports.count
        let square = try TransientExecutionBudget.multiply(n, n, "network matrix entries")
        let pointScalars = try TransientExecutionBudget.add(
            TransientExecutionBudget.multiply(square, 6, "network Y/S/Z scalars"), 16, "network metrics")
        let outputScalars = try TransientExecutionBudget.add(
            TransientExecutionBudget.multiply(frequencies.count, pointScalars, "network result scalars"),
            TransientExecutionBudget.multiply(dim, 2, "network DC coordinates"), "network result scalars")
        try TransientExecutionBudget.admit(outputScalars, limit: limits.maximumResultScalars, resource: "network.resultScalars")
        let budget: TransientExecutionBudget
        if let executionBudget { budget = executionBudget }
        else {
            budget = try TransientExecutionBudget(limits: limits.executionLimits, dimension: dim,
                nonZeroCount: plan.matrixStructure.nonZeroCount, deviceCount: devices.count)
        }
        let control = NetworkParameterControl(maximumBytes: limits.maximumTemporaryBytes, budget: budget,
            cancellation: cancellation, upstream: resultStorage)
        // Conservative live payload floor for DC/AC vectors, original matrices, port CSR/transforms and metadata.
        // Sparse factor fill has its own additional, exact managed-capacity leases.
        var scratchScalars = try TransientExecutionBudget.multiply(dim, 64, "network/DC vector scratch")
        scratchScalars = try TransientExecutionBudget.add(scratchScalars,
            TransientExecutionBudget.multiply(plan.matrixStructure.nonZeroCount, 12, "network/DC matrix scratch"), "network scratch")
        scratchScalars = try TransientExecutionBudget.add(scratchScalars,
            TransientExecutionBudget.multiply(square, 32, "network transform scratch"), "network scratch")
        scratchScalars = try TransientExecutionBudget.add(scratchScalars,
            TransientExecutionBudget.multiply(n, 64, "network port metadata"), "network scratch")
        let scratch = try control.reserveStorage(byteCount:
            TransientExecutionBudget.multiply(scratchScalars, MemoryLayout<Double>.stride, "network scratch bytes"))
        defer { withExtendedLifetime(scratch) {} }
        var branchOwnerCount = 0
        for instance in plan.ir.instances {
            branchOwnerCount = try TransientExecutionBudget.add(branchOwnerCount, instance.ownedBranches.count,
                "network ownership work")
        }
        let selectionWork = try TransientExecutionBudget.multiply(n,
            TransientExecutionBudget.add(branchOwnerCount,
                TransientExecutionBudget.multiply(TransientExecutionBudget.add(plan.ir.instances.count, n,
                    "network selection count"), 8, "network selection work"),
                "network selection work"), "network selection work")
        try control.checkpoint(workUnits: selectionWork)
        let branchIndices = try selectPorts(plan: plan, devices: devices)
        let id = AnalysisID()
        let start = Timestamp()
        await observer?.emit(.analysisStarted(AnalysisStartedInfo(id: id, type: .networkParameters,
            timestamp: start, nodeCount: plan.ir.nodes.count, deviceCount: devices.count)))
        do {
            try control.checkpoint(workUnits: ports.count)
            try budget.admitSavedScalars(outputScalars)
            try control.reserveResultScalars(outputScalars)
            var dc = DCAnalysis(config: dcConfig, nodeInitialGuess: nodeInitialGuess,
                equationPolicy: equationPolicy, physicalResidualValidator: physicalResidualValidator)
            dc.executionBudget = budget; dc.resultStorage = control
            let operatingPoint = try await dc.run(plan: plan, devices: devices, solver: solver,
                observer: observer, cancellation: cancellation)
            let state = SolutionState(variables: operatingPoint.variables, variableMap: plan.topology.variableMap,
                variableLowComponents: operatingPoint.variableLowComponents)
            var matrix = ComplexSparseMatrix(structure: plan.matrixStructure)
            var rhs = [ComplexPair](repeating: .zero, count: dim)
            var solution = [ComplexPair](repeating: .zero, count: dim)
            var residualBuffer = [ComplexPair](repeating: .zero, count: dim)
            var correctionBuffer = [ComplexPair](repeating: .zero, count: dim)
            var complexSolver = ComplexSparseLUSolver()
            try complexSolver.configureExecution(control)
            var points = [NetworkParameterPoint]()
            points.reserveCapacity(frequencies.count)
            for (index, frequency) in frequencies.enumerated() {
                try control.checkCancellation()
                await observer?.emit(.sweepPointStarted(SweepPointInfo(id: id, index: index,
                    total: frequencies.count, value: frequency, parameterName: "frequency")))
                try budget.beginLinearSolve(complex: true)
                matrix.clear()
                var stamper = ComplexMatrixStamper(variableMap: plan.topology.variableMap,
                    stampMatrix: { row, column, real, imaginary in
                        matrix.addValue(row: row, col: column, value: ComplexPair(real: real, imag: imaginary))
                    }, stampRHS: { _, _, _ in }, stampValue: { index, real, imaginary in
                        matrix.addValueDirect(at: index, value: ComplexPair(real: real, imag: imaginary))
                    })
                for device in devices {
                    try control.checkCancellation()
                    try device.stampAC(into: &stamper, state: state, omega: 2 * Double.pi * frequency)
                }
                try complexSolver.factorize(matrix: matrix)
                var yValues = [ComplexPair](repeating: .zero, count: square)
                var maximumResidual = 0.0
                for column in 0..<n {
                    try control.checkCancellation()
                    if column > 0 { try budget.beginRefinementSolve(complex: true) }
                    for row in 0..<dim { rhs[row] = .zero }
                    rhs[branchIndices[column]] = .one
                    maximumResidual = max(maximumResidual, try NetworkParameterTransforms.solveChecked(
                        matrix: matrix, rhs: rhs, solver: &complexSolver, solution: &solution,
                        residualBuffer: &residualBuffer, correctionBuffer: &correctionBuffer,
                        tolerance: limits.residualTolerance, control: control))
                    for row in 0..<n {
                        let current = solution[branchIndices[row]]
                        yValues[row * n + column] = ComplexPair(real: -current.real, imag: -current.imag)
                    }
                }
                let y = try NetworkParameterMatrix(portCount: n, values: yValues)
                let converted = try NetworkParameterTransforms.convert(y: y, ports: ports,
                    tolerance: limits.residualTolerance, control: control)
                try control.checkpoint(workUnits: n == 2 ? 128 : 0)
                let stability = n == 2 ? try TwoPortStability(scattering: converted.s) : nil
                points.append(NetworkParameterPoint(frequency: frequency, y: y, s: converted.s, z: converted.z,
                    stability: stability, maximumBackwardResidual: max(maximumResidual, converted.residual)))
                await observer?.emit(.sweepPointFinished(SweepPointResultInfo(id: id, index: index,
                    value: frequency, parameterName: "frequency", converged: true, iterations: n)))
            }
            try control.checkCancellation()
            try completionFinalizer?.finalizeCompletion()
            try control.checkCancellation()
            var result = NetworkParameterResult(ports: ports, points: points, operatingPoint: operatingPoint)
            if let resultStorage { result = result.retainingStorage(resultStorage) }
            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(id: id, type: .networkParameters,
                status: .completed, timestamp: Timestamp(), wallTime: Timestamp().elapsed(since: start))))
            return result
        } catch {
            let status: AnalysisStatus
            if case AnalysisError.cancelled = error { status = .cancelled } else { status = .failed }
            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(id: id, type: .networkParameters,
                status: status, timestamp: Timestamp(), wallTime: Timestamp().elapsed(since: start),
                failure: status.failureInfo(for: error))))
            throw error
        }
    }

    private func selectPorts(plan: ExecutionPlan, devices: [any BoundDevice]) throws -> [Int] {
        try equationPolicy?.validate(dimension: plan.topology.dimension,
            variableMap: plan.topology.variableMap, config: dcConfig)
        var indices = [Int]()
        indices.reserveCapacity(ports.count)
        var parents = [Node: Node]()
        func root(_ node: Node) -> Node {
            var current = node
            while let next = parents[current], next != current { current = next }
            return current
        }
        for port in ports {
            var sourceIndex: Int?
            for (index, instance) in plan.ir.instances.enumerated()
                where instance.name.caseInsensitiveCompare(port.voltageSourceName) == .orderedSame {
                guard sourceIndex == nil else { throw NetworkParameterError.invalidPort(port.voltageSourceName) }
                sourceIndex = index
            }
            guard let sourceIndex else { throw NetworkParameterError.invalidPort(port.voltageSourceName) }
            let source = plan.ir.instances[sourceIndex]
            guard source.typeName == "vsource", devices[sourceIndex] is BoundVoltageSource,
                  source.nodes.count == 2, source.nodes[0] != source.nodes[1], source.ownedBranches.count == 1,
                  devices[sourceIndex].instance.ownedBranches == source.ownedBranches,
                  let branch = source.ownedBranches.first,
                  let index = plan.topology.variableMap[.branchCurrent(branch)],
                  index >= 0, index < plan.topology.dimension,
                  !indices.contains(index) else { throw NetworkParameterError.invalidPort(port.voltageSourceName) }
            var owners = 0
            for instance in plan.ir.instances {
                for owned in instance.ownedBranches where owned == branch { owners += 1 }
            }
            guard owners == 1 else { throw NetworkParameterError.invalidPort(port.voltageSourceName) }
            for node in source.nodes {
                guard node == .ground || plan.topology.variableMap[.nodeVoltage(node)] != nil else {
                    throw NetworkParameterError.invalidPort(port.voltageSourceName)
                }
                try equationPolicy?.requireElectricalEndpoint(node, variableMap: plan.topology.variableMap,
                    context: "Network port")
            }
            let positiveRoot = root(source.nodes[0]), negativeRoot = root(source.nodes[1])
            guard positiveRoot != negativeRoot else { throw NetworkParameterError.dependentPorts }
            parents[positiveRoot] = negativeRoot
            indices.append(index)
        }
        return indices
    }
}

import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent

/// Transfer function (.tf) analysis.
///
/// Computes the small-signal DC transfer function from an input source
/// to an output node. The analysis proceeds in three phases:
///
/// 1. **DC operating point**: Full DC analysis to find the linearization point.
/// 2. **Gain and input impedance**: Apply unit voltage excitation at the
///    input source and solve for the output voltage and input current.
/// 3. **Output impedance**: Inject unit current at the output node
///    (with the input source shorted) and solve for the resulting voltage.
///
/// The result provides gain (Vout/Vin), input impedance (Zin),
/// and output impedance (Zout).
public struct TransferFunctionAnalysis: Analysis, Sendable {
    package var executionBudget: TransientExecutionBudget?
    package var resultStorage: (any AnalysisResultStorageAccounting)?

    public typealias Result = TransferFunctionResult

    /// The output node for the transfer function.
    public let outputNode: Node

    /// The name of the input voltage source (e.g., "V1").
    public let inputSourceName: String

    /// Convergence configuration for the DC operating point solve.
    public let dcConfig: ConvergenceConfig
    public let equationPolicy: DCEquationPolicy?
    public let physicalResidualValidator: (any DCPhysicalResidualValidating)?
    public let completionFinalizer: (any AnalysisCompletionFinalizing)?

    public init(
        outputNode: Node,
        inputSourceName: String,
        dcConfig: ConvergenceConfig = ConvergenceConfig(),
        equationPolicy: DCEquationPolicy? = nil,
        physicalResidualValidator: (any DCPhysicalResidualValidating)? = nil,
        completionFinalizer: (any AnalysisCompletionFinalizing)? = nil
    ) {
        self.outputNode = outputNode
        self.inputSourceName = inputSourceName
        self.dcConfig = dcConfig
        self.equationPolicy = equationPolicy
        self.physicalResidualValidator = physicalResidualValidator
        self.completionFinalizer = completionFinalizer
    }

    public func run(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: any LinearSolver,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> TransferFunctionResult {
        try PreparedCircuit.validate(plan: plan, devices: devices)
        let analysisID = AnalysisID()
        let startTimestamp = Timestamp()
        let dim = plan.topology.dimension
        let variableMap = plan.topology.variableMap

        await observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .tf,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        do {
            // Phase 1: DC operating point
            var dcAnalysis = DCAnalysis(config: dcConfig, equationPolicy: equationPolicy,
                physicalResidualValidator: physicalResidualValidator)
            dcAnalysis.executionBudget = executionBudget
            dcAnalysis.resultStorage = resultStorage
            try executionBudget?.admitSavedPoint(accepted: false)
            let dcResult = try await dcAnalysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: observer,
                cancellation: cancellation
            )

            let dcState = SolutionState(
                variables: dcResult.variables,
                variableMap: variableMap,
                variableLowComponents: dcResult.variableLowComponents
            )

            // Find the input source branch index
            let inputBranchIndex = try findInputSourceBranchIndex(
                plan: plan,
                devices: devices
            )

            // Find the output node index
            guard let outputNodeIndex = variableMap[.nodeVoltage(outputNode)] else {
                throw AnalysisError.invalidConfiguration(
                    "Output node \(outputNode.id) not found in variable map"
                )
            }

            try equationPolicy?.requireElectricalEndpoint(outputNode, variableMap: variableMap,
                context: "Transfer-function voltage output")

            try executionBudget?.beginLinearSolve()

            // Phase 2: Build the linearized G matrix at the operating point
            var gMatrix = SparseMatrix(structure: plan.matrixStructure)

            // Stamp all devices at the operating point
            var stamper = MatrixStamper(
                variableMap: variableMap,
                stampMatrix: { row, col, val in
                    gMatrix.addValue(row: row, col: col, value: val)
                },
                stampRHS: { _, _ in
                    // Discard RHS contributions from device stamps.
                    // We'll construct our own excitation vectors.
                },
                stampValue: { idx, val in
                    gMatrix.addValueDirect(at: idx, value: val)
                }
            )

            for device in devices {
                try device.stampDC(into: &stamper, state: dcState)
            }

            // Phase 3: Factor the matrix
            var mutableSolver = solver
            if executionBudget != nil || resultStorage != nil {
                try mutableSolver.configureExecution(AnalysisLinearSolverControl.make(budget: executionBudget,
                    cancellation: cancellation, storage: resultStorage))
            }
            do {
                try mutableSolver.factorize(matrix: gMatrix)
            } catch {
                if case CompileError.singularMatrix = error { throw AnalysisError.singularMatrix }
                throw error
            }

            // Phase 4: Solve for gain and input impedance
            // Apply unit voltage excitation: rhs[inputBranch] = 1.0
            var gainRHS = [Double](repeating: 0, count: dim)
            gainRHS[inputBranchIndex] = 1.0

            let gainSolution: [Double]
            do {
                gainSolution = try mutableSolver.solve(rhs: gainRHS)
            } catch {
                throw error
            }

            let gain = gainSolution[outputNodeIndex]
            // In MNA convention, the branch current variable represents current
            // flowing INTO the positive terminal. The input current flowing through
            // the external circuit is the negation of this.
            let branchCurrent = gainSolution[inputBranchIndex]
            let inputImpedance = try PortImpedance(reciprocalOf: -branchCurrent)

            // Phase 5: Solve for output impedance
            // Inject unit current at the output node (input source is shorted: rhs[branch] = 0)
            try executionBudget?.beginRefinementSolve()
            var zoutRHS = [Double](repeating: 0, count: dim)
            zoutRHS[outputNodeIndex] = 1.0

            let zoutSolution: [Double]
            do {
                zoutSolution = try mutableSolver.solve(rhs: zoutRHS)
            } catch {
                throw error
            }

            let outputImpedance = zoutSolution[outputNodeIndex]
            try executionBudget?.admitSavedScalars(3)

            let result = try TransferFunctionResult(
                gain: gain,
                inputPortImpedance: inputImpedance,
                outputPortImpedance: .finite(outputImpedance),
                dcOperatingPoint: dcResult,
                variableMap: variableMap
            )
            if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
            try completionFinalizer?.finalizeCompletion()
            if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .tf,
                status: .completed,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            return result
        } catch {
            let status: AnalysisStatus
            if let analysisError = error as? AnalysisError,
               case .cancelled = analysisError {
                status = .cancelled
            } else {
                status = .failed
            }

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .tf,
                status: status,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp),
                failure: status.failureInfo(for: error)
            )))

            throw error
        }
    }

    // MARK: - Private

    /// Finds the matrix index of the branch current variable for the named input voltage source.
    ///
    /// Explicit source ownership is authoritative. Ownership-free legacy IR retains
    /// its historical sequential allocation compatibility path.
    private func findInputSourceBranchIndex(
        plan: ExecutionPlan,
        devices: [any BoundDevice]
    ) throws -> Int {
        let variableMap = plan.topology.variableMap

        guard let source = plan.ir.instances.first(where: {
            $0.name.caseInsensitiveCompare(inputSourceName) == .orderedSame
        }), source.typeName == "vsource" else {
            throw AnalysisError.invalidConfiguration(
                "Input source '\(inputSourceName)' must name an independent voltage source"
            )
        }
        if let branch = source.ownedBranches.first {
            guard source.ownedBranches.count == 1,
                  let index = variableMap[.branchCurrent(branch)] else {
                throw AnalysisError.invalidConfiguration(
                    "Owned branch for input source '\(inputSourceName)' is invalid"
                )
            }
            return index
        }

        // Device types that allocate branches during binding
        let branchAllocatingTypes: Set<String> = [
            "vsource", "inductor", "vcvs", "ccvs", "cccs", "ccvs_ref", "cswitch"
        ]

        // CCVS allocates 2 branches (sense + output); all others in this set allocate 1.
        var branchID = 0
        for instance in plan.ir.instances {
            guard branchAllocatingTypes.contains(instance.typeName) else { continue }

            if instance.name.caseInsensitiveCompare(inputSourceName) == .orderedSame {
                guard instance.typeName == "vsource" else {
                    throw AnalysisError.invalidConfiguration(
                        "Input source '\(inputSourceName)' must be an independent voltage source, got \(instance.typeName)"
                    )
                }
                let branch = Branch(id: branchID)
                guard let index = variableMap[.branchCurrent(branch)] else {
                    throw AnalysisError.invalidConfiguration(
                        "Branch for input source '\(inputSourceName)' not found in variable map"
                    )
                }
                return index
            }

            if instance.typeName == "ccvs" {
                branchID += 2  // sense + output branches
            } else {
                branchID += 1
            }
        }

        throw AnalysisError.invalidConfiguration(
            "Input source '\(inputSourceName)' not found in circuit"
        )
    }
}

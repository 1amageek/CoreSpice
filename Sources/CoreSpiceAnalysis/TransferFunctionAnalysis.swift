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

    public typealias Result = TransferFunctionResult

    /// The output node for the transfer function.
    public let outputNode: Node

    /// The name of the input voltage source (e.g., "V1").
    public let inputSourceName: String

    /// Convergence configuration for the DC operating point solve.
    public let dcConfig: ConvergenceConfig

    public init(
        outputNode: Node,
        inputSourceName: String,
        dcConfig: ConvergenceConfig = ConvergenceConfig()
    ) {
        self.outputNode = outputNode
        self.inputSourceName = inputSourceName
        self.dcConfig = dcConfig
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
            let dcAnalysis = DCAnalysis(config: dcConfig)
            let dcResult = try await dcAnalysis.run(
                plan: plan,
                devices: devices,
                solver: solver,
                observer: observer,
                cancellation: cancellation
            )

            let dcState = SolutionState(
                variables: dcResult.variables,
                variableMap: variableMap
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
                device.stampDC(into: &stamper, state: dcState)
            }

            // Add Gmin to diagonal for numerical stability
            for i in 0..<dim {
                gMatrix.addValue(row: i, col: i, value: dcConfig.gmin)
            }

            // Phase 3: Factor the matrix
            var mutableSolver = solver
            do {
                try mutableSolver.factorize(matrix: gMatrix)
            } catch {
                throw AnalysisError.singularMatrix
            }

            // Phase 4: Solve for gain and input impedance
            // Apply unit voltage excitation: rhs[inputBranch] = 1.0
            var gainRHS = [Double](repeating: 0, count: dim)
            gainRHS[inputBranchIndex] = 1.0

            let gainSolution: [Double]
            do {
                gainSolution = try mutableSolver.solve(rhs: gainRHS)
            } catch {
                throw AnalysisError.internalError(
                    "Failed to solve for gain: \(error)"
                )
            }

            let gain = gainSolution[outputNodeIndex]
            // In MNA convention, the branch current variable represents current
            // flowing INTO the positive terminal. The input current flowing through
            // the external circuit is the negation of this.
            let branchCurrent = gainSolution[inputBranchIndex]
            let inputImpedance: Double
            if abs(branchCurrent) > 1e-30 {
                inputImpedance = -1.0 / branchCurrent
            } else {
                inputImpedance = .infinity
            }

            // Phase 5: Solve for output impedance
            // Inject unit current at the output node (input source is shorted: rhs[branch] = 0)
            var zoutRHS = [Double](repeating: 0, count: dim)
            zoutRHS[outputNodeIndex] = 1.0

            let zoutSolution: [Double]
            do {
                zoutSolution = try mutableSolver.solve(rhs: zoutRHS)
            } catch {
                throw AnalysisError.internalError(
                    "Failed to solve for output impedance: \(error)"
                )
            }

            let outputImpedance = zoutSolution[outputNodeIndex]

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .tf,
                status: .completed,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            return try TransferFunctionResult(
                gain: gain,
                inputImpedance: inputImpedance,
                outputImpedance: outputImpedance,
                dcOperatingPoint: dcResult,
                variableMap: variableMap
            )
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
    /// Branch variables are allocated sequentially during device binding. This method
    /// reconstructs the branch-to-device mapping by scanning instances in IR order
    /// and tracking which device types allocate branches.
    private func findInputSourceBranchIndex(
        plan: ExecutionPlan,
        devices: [any BoundDevice]
    ) throws -> Int {
        let variableMap = plan.topology.variableMap

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

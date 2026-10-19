import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent
import Foundation

/// Pole-zero (.pz) analysis.
///
/// Computes the poles and zeros of a circuit transfer function from a
/// differential voltage or current input to a differential voltage output.
/// The analysis proceeds as follows:
///
/// 1. **DC operating point**: Finds the linearization point.
/// 2. **Matrix extraction**: For explicitly affine devices, stamps at `ω = 1` to obtain
///    the conductance matrix `G` (real parts) and susceptance matrix `C`
///    (imaginary parts) from the complex MNA equation `(G + sC)x = 0`.
/// 3. **Pole computation**: Solves the generalized eigenvalue problem
///    `G·v = λ·C·v` using the Pure Swift generalized Schur algorithm. Poles are `s = −λ`.
/// 4. **Zero computation**: Builds the Rosenbrock system pencil from
///    `G`, `C`, the input vector, and the output vector.
/// 5. **DC gain**: Solves the linearized DC system with the unit excitation.
public struct PoleZeroAnalysis: Analysis, Sendable {
    package var executionBudget: TransientExecutionBudget?
    package var resultStorage: (any AnalysisResultStorageAccounting)?

    public typealias Result = PoleZeroResult

    /// The small-signal input port.
    public let input: PoleZeroInput

    /// The positive output node.
    public let outputPositiveNode: Node

    /// The output reference node.
    public let outputReferenceNode: Node

    /// DC convergence configuration.
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
        self.input = .voltageSource(name: inputSourceName)
        self.outputPositiveNode = outputNode
        self.outputReferenceNode = .ground
        self.dcConfig = dcConfig
        self.equationPolicy = equationPolicy
        self.physicalResidualValidator = physicalResidualValidator
        self.completionFinalizer = completionFinalizer
    }

    public init(
        input: PoleZeroInput,
        outputPositiveNode: Node,
        outputReferenceNode: Node = .ground,
        dcConfig: ConvergenceConfig = ConvergenceConfig(),
        equationPolicy: DCEquationPolicy? = nil,
        physicalResidualValidator: (any DCPhysicalResidualValidating)? = nil,
        completionFinalizer: (any AnalysisCompletionFinalizing)? = nil
    ) {
        self.input = input
        self.outputPositiveNode = outputPositiveNode
        self.outputReferenceNode = outputReferenceNode
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
    ) async throws -> PoleZeroResult {
        try PreparedCircuit.validate(plan: plan, devices: devices)
        let analysisID = AnalysisID()
        let startTimestamp = Timestamp()
        let dim = plan.topology.dimension
        let variableMap = plan.topology.variableMap

        await observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .pz,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        do {
            for device in devices {
                if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
                if case .unsupported(let reason) = device.poleZeroStampApplicability {
                    throw AnalysisError.unsupportedPoleZeroDevice(instance: device.instance.name, reason: reason)
                }
            }
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

            if let equationPolicy {
                var endpoints = [outputPositiveNode, outputReferenceNode]
                switch input {
                case .current(let positive, let reference), .voltage(let positive, let reference):
                    endpoints.append(contentsOf: [positive, reference])
                case .voltageSource(let name):
                    if let source = plan.ir.instances.first(where: {
                        $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.typeName == "vsource"
                    }) { endpoints.append(contentsOf: source.nodes) }
                }
                for node in endpoints {
                    try equationPolicy.requireElectricalEndpoint(node, variableMap: variableMap,
                        context: "Pole-zero electrical port")
                }
            }

            let control = AnalysisLinearSolverControl(budget: executionBudget, cancellation: cancellation, storage: resultStorage)
            try control.checkpoint(workUnits: 0)
            let augmentedDimension = try TransientExecutionBudget.add(dim, 1, "zero pencil dimension")
            // Caller planes coexist with the separately admitted QZ/LU workspaces.
            let square = try TransientExecutionBudget.multiply(dim, dim, "pole-zero caller square")
            let augmentedSquare = try TransientExecutionBudget.multiply(augmentedDimension, augmentedDimension,
                                                                        "pole-zero augmented square")
            var scalarCount = try TransientExecutionBudget.add(
                TransientExecutionBudget.multiply(square, 4, "pole-zero G/C planes"),
                TransientExecutionBudget.multiply(augmentedSquare, 2, "pole-zero Rosenbrock planes"),
                "pole-zero caller planes")
            scalarCount = try TransientExecutionBudget.add(scalarCount,
                TransientExecutionBudget.multiply(plan.matrixStructure.nonZeroCount, 2, "pole-zero complex CSR"),
                "pole-zero caller scalars")
            scalarCount = try TransientExecutionBudget.add(scalarCount,
                TransientExecutionBudget.multiply(dim, 2, "pole-zero port vectors"), "pole-zero caller scalars")
            let arrayValues = try TransientExecutionBudget.add(
                TransientExecutionBudget.multiply(dim, 2, "pole-zero row array values"), 12, "pole-zero array values")
            let callerBytes = try TransientExecutionBudget.add(
                TransientExecutionBudget.multiply(scalarCount, MemoryLayout<Double>.stride, "pole-zero caller bytes"),
                TransientExecutionBudget.multiply(arrayValues, MemoryLayout<Array<Double>>.stride, "pole-zero array value bytes"),
                "pole-zero caller storage")
            let callerStorage = try control.reserveStorage(byteCount: callerBytes)
            defer { withExtendedLifetime(callerStorage) {} }
            try executionBudget?.beginLinearSolve()
            let inputVector = try makeInputVector(plan: plan, dimension: dim)
            let outputVector = try makeOutputVector(plan: plan, dimension: dim)

            // Phase 2: Extract G and C dense matrices from AC stamps at ω = 1
            let (gDense, cDense) = try extractGCMatrices(
                plan: plan,
                devices: devices,
                dcState: dcState,
                dim: dim,
                variableMap: variableMap, control: control
            )

            // Phase 3: DC gain from the G matrix (s=0 response)
            let dcGain = try computeDCGainFromG(
                gDense: gDense,
                dim: dim,
                inputVector: inputVector,
                outputVector: outputVector,
                structure: plan.matrixStructure,
                solver: solver,
                control: control
            )

            await observer?.emit(.progressUpdate(try ProgressInfo(
                id: analysisID,
                fraction: 0.3,
                message: "Computing poles"
            )))

            // Phase 4: Poles — solve G·v = λ·C·v, then s = −λ
            try executionBudget?.beginLinearSolve()
            let gColMajor = try toColumnMajor(gDense, dim: dim, control: control)
            let cColMajor = try toColumnMajor(cDense, dim: dim, control: control)

            let poleResult = try GeneralizedEigenSolver.solve(
                matrixA: gColMajor,
                matrixB: cColMajor,
                dimension: dim, control: control
            )

            try executionBudget?.admitSavedScalars(TransientExecutionBudget.multiply(poleResult.eigenvalues.count, 2, "pole complex scalars"))
            try resultStorage?.reserveResultScalars(TransientExecutionBudget.add(dim,
                TransientExecutionBudget.add(TransientExecutionBudget.multiply(poleResult.eigenvalues.count, 2,
                    "pole output storage"), 1, "pole gain storage"), "pole OP coexistence"))
            let poles = poleResult.eigenvalues.map { lambda in
                ComplexPair(real: -lambda.real, imag: -lambda.imag)
            }

            await observer?.emit(.progressUpdate(try ProgressInfo(
                id: analysisID,
                fraction: 0.7,
                message: "Computing zeros"
            )))

            try executionBudget?.beginLinearSolve(dimension: augmentedDimension)
            let zeroPencil = try makeZeroPencil(
                gDense: gDense,
                cDense: cDense,
                inputVector: inputVector,
                outputVector: outputVector,
                dimension: dim, control: control
            )
            let zeroResult = try GeneralizedEigenSolver.solve(
                matrixA: zeroPencil.a,
                matrixB: zeroPencil.b,
                dimension: augmentedDimension, control: control
            )
            try executionBudget?.admitSavedScalars(TransientExecutionBudget.add(
                TransientExecutionBudget.multiply(zeroResult.eigenvalues.count, 2, "zero complex scalars"), 1, "DC gain scalar"))
            let complexOutputs = try TransientExecutionBudget.add(poles.count, zeroResult.eigenvalues.count,
                                                                  "pole-zero output entries")
            try resultStorage?.reserveResultScalars(TransientExecutionBudget.add(dim,
                TransientExecutionBudget.add(TransientExecutionBudget.multiply(complexOutputs, 2,
                    "pole-zero output storage"), 1, "pole-zero gain storage"), "pole-zero OP coexistence"))
            let zeros = zeroResult.eigenvalues.map { lambda in
                ComplexPair(real: -lambda.real, imag: -lambda.imag)
            }

            let result = try PoleZeroResult(
                poles: poles,
                zeros: zeros,
                dcGain: dcGain,
                variableMap: variableMap
            )
            if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
            try completionFinalizer?.finalizeCompletion()
            if cancellation.isCancelled || Task.isCancelled { throw AnalysisError.cancelled }
            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .pz,
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
                type: .pz,
                status: status,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp),
                failure: status.failureInfo(for: error)
            )))

            throw error
        }
    }

    // MARK: - Private

    /// Extracts the G (conductance) and C (susceptance) dense matrices
    /// by stamping the AC model at `ω = 1`. Real parts give G; imaginary
    /// parts give C.
    private func extractGCMatrices(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        dcState: SolutionState,
        dim: Int,
        variableMap: [MNAVariable: Int],
        control: AnalysisLinearSolverControl
    ) throws -> (g: [[Double]], c: [[Double]]) {
        try control.checkpoint(workUnits: TransientExecutionBudget.multiply(plan.matrixStructure.nonZeroCount, 2, "pole-zero CSR initialization"))
        var matrix = ComplexSparseMatrix(structure: plan.matrixStructure)

        var stamper = ComplexMatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, col, re, im in
                matrix.addValue(row: row, col: col, value: ComplexPair(real: re, imag: im))
            },
            stampRHS: { _, _, _ in
                // RHS not needed for G/C extraction
            },
            stampValue: { index, real, imag in
                matrix.addValueDirect(at: index, value: ComplexPair(real: real, imag: imag))
            }
        )

        // Stamp at ω = 1 so that imaginary parts equal the C coefficients
        let omega = 1.0
        for device in devices {
            try control.checkpoint(workUnits: 4)
            try device.stampAC(into: &stamper, state: dcState, omega: omega)
        }
        try control.checkpoint(workUnits: 0)
        guard matrix.structuralMisses.isEmpty else {
            let first = matrix.structuralMisses[0]
            throw AnalysisError.internalError(
                "Pole-zero AC stamp missed matrix position (\(first.row), \(first.col))"
            )
        }

        let square = try TransientExecutionBudget.multiply(dim, dim, "pole-zero G/C initialization")
        try control.checkpoint(workUnits: TransientExecutionBudget.multiply(square, 2, "pole-zero G/C initialization"))
        var g = Array(repeating: Array(repeating: 0.0, count: dim), count: dim)
        var c = Array(repeating: Array(repeating: 0.0, count: dim), count: dim)
        // Read the original compiled CSR directly; no intermediate dense complex plane.
        for row in 0..<dim {
            try control.checkpoint(workUnits: 1)
            let first = matrix.structure.rowPointers[row], last = matrix.structure.rowPointers[row + 1]
            for slot in first..<last {
                if (slot - first) % 32 == 0 { try control.checkpoint(workUnits: min(32, last - slot) * 4) }
                let column = matrix.structure.columnIndices[slot], value = matrix.values[slot]
                guard value.real.isFinite, value.imag.isFinite else {
                    throw AnalysisError.internalError("Pole-zero AC matrix contains a non-finite value")
                }
                g[row][column] = value.real
                c[row][column] = value.imag
            }
        }

        return (g, c)
    }

    private enum LinearResponseError: Error {
        case invalidResidual(row: Int)
        case nonFiniteArithmetic
    }

    /// Solves the same original G using the existing controlled Swift sparse LU.
    private func computeDCGainFromG(
        gDense: [[Double]], dim: Int, inputVector: [Double], outputVector: [Double],
        structure: SparseStructure, solver: any LinearSolver,
        control: AnalysisLinearSolverControl
    ) throws -> Double {
        guard dim > 0 else {
            throw AnalysisError.invalidConfiguration("Pole-zero analysis requires a non-empty MNA system")
        }
        let sparseBytes = try TransientExecutionBudget.multiply(structure.nonZeroCount, MemoryLayout<Double>.stride,
                                                                 "pole-zero G sparse values")
        let vectorBytes = try TransientExecutionBudget.multiply(dim, MemoryLayout<Double>.stride,
                                                                 "pole-zero gain vectors")
        let storage = try control.reserveStorage(byteCount: TransientExecutionBudget.add(sparseBytes, vectorBytes,
                                                                                       "pole-zero gain storage"))
        defer { withExtendedLifetime(storage) {} }
        var matrix = SparseMatrix(structure: structure)
        for row in 0..<dim {
            for slot in structure.rowPointers[row]..<structure.rowPointers[row + 1] {
                if slot % 32 == 0 { try control.checkpoint(workUnits: min(32, structure.nonZeroCount - slot) * 2) }
                matrix.addValueDirect(at: slot, value: gDense[row][structure.columnIndices[slot]])
            }
        }
        var gainSolver = solver
        if executionBudget != nil || resultStorage != nil { try gainSolver.configureExecution(control) }
        let solution: [Double]
        do {
            try gainSolver.factorize(matrix: matrix)
            solution = try gainSolver.solve(rhs: inputVector)
        } catch CompileError.singularMatrix { throw AnalysisError.singularMatrix }
        try control.checkpoint(workUnits: 0)
        // Componentwise backward error in the original G, with compensated products/sums.
        // This is a numerical linear-response check, independent of source/OP tolerances.
        for row in 0..<dim {
            var sum = -inputVector[row], correction = 0.0, magnitude = abs(inputVector[row])
            let first = structure.rowPointers[row], last = structure.rowPointers[row + 1]
            for slot in first..<last {
                if (slot - first) % 32 == 0 { try control.checkpoint(workUnits: min(32, last - slot) * 24) }
                let coefficient = matrix.values[slot], x = solution[structure.columnIndices[slot]]
                let product = coefficient * x
                let productError = (-product).addingProduct(coefficient, x)
                let next = sum + product
                correction += abs(sum) >= abs(product) ? (sum - next) + product : (product - next) + sum
                correction += productError
                sum = next; magnitude += abs(product)
                guard product.isFinite, correction.isFinite, sum.isFinite, magnitude.isFinite else {
                    throw LinearResponseError.nonFiniteArithmetic
                }
            }
            let residual = sum + correction
            let bound = 128 * Double(max(1, last - first)) * Double.ulpOfOne * magnitude
            guard residual.isFinite, abs(residual) <= bound else {
                throw LinearResponseError.invalidResidual(row: row)
            }
        }
        var gain = 0.0
        for index in 0..<dim {
            if index % 32 == 0 { try control.checkpoint(workUnits: min(32, dim - index) * 2) }
            gain = gain.addingProduct(outputVector[index], solution[index])
        }
        guard gain.isFinite else { throw LinearResponseError.nonFiniteArithmetic }
        return gain
    }

    private func makeInputVector(
        plan: ExecutionPlan,
        dimension: Int
    ) throws -> [Double] {
        var vector = [Double](repeating: 0.0, count: dimension)
        switch input {
        case .current(let positive, let reference):
            guard positive != reference else {
                throw AnalysisError.invalidConfiguration(
                    "Pole-zero current input nodes must be distinct"
                )
            }
            if positive != plan.ir.groundNode {
                guard let index = plan.topology.variableMap[.nodeVoltage(positive)] else {
                    throw AnalysisError.invalidConfiguration(
                        "Pole-zero input node \(positive.id) is not present in the circuit"
                    )
                }
                vector[index] = -1.0
            }
            if reference != plan.ir.groundNode {
                guard let index = plan.topology.variableMap[.nodeVoltage(reference)] else {
                    throw AnalysisError.invalidConfiguration(
                        "Pole-zero input reference node \(reference.id) is not present in the circuit"
                    )
                }
                vector[index] = 1.0
            }
        case .voltage(let positive, let reference):
            guard positive != reference else {
                throw AnalysisError.invalidConfiguration(
                    "Pole-zero voltage input nodes must be distinct"
                )
            }
            let matches = plan.ir.instances.filter {
                $0.typeName == "vsource"
                    && $0.nodes.count == 2
                    && (($0.nodes[0] == positive && $0.nodes[1] == reference)
                        || ($0.nodes[0] == reference && $0.nodes[1] == positive))
            }
            guard matches.count == 1, let source = matches.first else {
                throw AnalysisError.invalidConfiguration(
                    matches.isEmpty
                        ? "Pole-zero voltage input requires one independent voltage source across the input port"
                        : "Pole-zero voltage input is ambiguous because multiple voltage sources span the input port"
                )
            }
            let index = try findInputSourceBranchIndex(
                sourceName: source.name,
                plan: plan
            )
            vector[index] = source.nodes[0] == positive ? 1.0 : -1.0
        case .voltageSource(let name):
            let index = try findInputSourceBranchIndex(
                sourceName: name,
                plan: plan
            )
            vector[index] = 1.0
        }
        return vector
    }

    private func makeOutputVector(
        plan: ExecutionPlan,
        dimension: Int
    ) throws -> [Double] {
        guard outputPositiveNode != outputReferenceNode else {
            throw AnalysisError.invalidConfiguration(
                "Pole-zero output nodes must be distinct"
            )
        }
        var vector = [Double](repeating: 0.0, count: dimension)
        if outputPositiveNode != plan.ir.groundNode {
            guard let index = plan.topology.variableMap[.nodeVoltage(outputPositiveNode)] else {
                throw AnalysisError.invalidConfiguration(
                    "Pole-zero output node \(outputPositiveNode.id) is not present in the circuit"
                )
            }
            vector[index] = 1.0
        }
        if outputReferenceNode != plan.ir.groundNode {
            guard let index = plan.topology.variableMap[.nodeVoltage(outputReferenceNode)] else {
                throw AnalysisError.invalidConfiguration(
                    "Pole-zero output reference node \(outputReferenceNode.id) is not present in the circuit"
                )
            }
            vector[index] = -1.0
        }
        return vector
    }

    /// Finds the matrix index of an independent voltage source branch variable.
    private func findInputSourceBranchIndex(
        sourceName: String,
        plan: ExecutionPlan
    ) throws -> Int {
        let variableMap = plan.topology.variableMap

        guard let source = plan.ir.instances.first(where: {
            $0.name.caseInsensitiveCompare(sourceName) == .orderedSame
                && $0.typeName == "vsource"
        }) else {
            throw AnalysisError.invalidConfiguration(
                "Input voltage source '\(sourceName)' not found in circuit"
            )
        }

        if let branch = source.ownedBranches.first {
            guard source.ownedBranches.count == 1,
                  let index = variableMap[.branchCurrent(branch)] else {
                throw AnalysisError.invalidConfiguration(
                    "Owned branch for input source '\(sourceName)' is invalid"
                )
            }
            return index
        }

        if let namedBranch = plan.ir.branchNames.first(where: {
            $0.value.caseInsensitiveCompare(source.name) == .orderedSame
        })?.key,
           let index = variableMap[.branchCurrent(namedBranch)] {
            return index
        }

        let branchAllocatingTypes: Set<String> = [
            "vsource", "inductor", "vcvs", "ccvs", "cccs", "ccvs_ref", "cswitch"
        ]

        var branchID = 0
        for instance in plan.ir.instances {
            guard branchAllocatingTypes.contains(instance.typeName) else { continue }

            if instance.name.caseInsensitiveCompare(source.name) == .orderedSame {
                let branch = Branch(id: branchID)
                guard let index = variableMap[.branchCurrent(branch)] else {
                    throw AnalysisError.invalidConfiguration(
                    "Branch for input source '\(source.name)' not found in variable map"
                    )
                }
                return index
            }

            if instance.typeName == "ccvs" {
                branchID += 2
            } else {
                branchID += 1
            }
        }

        throw AnalysisError.invalidConfiguration(
            "Branch for input source '\(source.name)' not found in circuit"
        )
    }

    /// Converts the existing dense extraction to the Schur component layout.
    private func toColumnMajor(_ matrix: [[Double]], dim: Int, control: AnalysisLinearSolverControl) throws -> [Double] {
        let square = try TransientExecutionBudget.multiply(dim, dim, "pole-zero column-major size")
        try control.checkpoint(workUnits: square)
        var colMajor = [Double](repeating: 0, count: square)
        for row in 0..<dim {
            for col in 0..<dim {
                if col % 32 == 0 { try control.checkpoint(workUnits: min(32, dim - col)) }
                colMajor[col * dim + row] = matrix[row][col]
            }
        }
        return colMajor
    }

    private func makeZeroPencil(
        gDense: [[Double]],
        cDense: [[Double]],
        inputVector: [Double],
        outputVector: [Double],
        dimension: Int,
        control: AnalysisLinearSolverControl
    ) throws -> (a: [Double], b: [Double]) {
        let augmentedDimension = try TransientExecutionBudget.add(dimension, 1, "pole-zero augmented dimension")
        let square = try TransientExecutionBudget.multiply(augmentedDimension, augmentedDimension, "pole-zero augmented square")
        try control.checkpoint(workUnits: TransientExecutionBudget.multiply(square, 2, "pole-zero pencil initialization"))
        var a = [Double](
            repeating: 0.0,
            count: square
        )
        var b = a
        for row in 0..<dimension {
            for column in 0..<dimension {
                if column % 32 == 0 { try control.checkpoint(workUnits: min(32, dimension - column) * 2) }
                a[column * augmentedDimension + row] = gDense[row][column]
                b[column * augmentedDimension + row] = cDense[row][column]
            }
            a[dimension * augmentedDimension + row] = -inputVector[row]
            a[row * augmentedDimension + dimension] = outputVector[row]
        }
        return (a, b)
    }
}

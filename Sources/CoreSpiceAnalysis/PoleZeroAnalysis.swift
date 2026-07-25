import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent
import Foundation
import CoreSpiceLAPACK

/// Pole-zero (.pz) analysis.
///
/// Computes the poles and zeros of a circuit transfer function from a
/// differential voltage or current input to a differential voltage output.
/// The analysis proceeds as follows:
///
/// 1. **DC operating point**: Finds the linearization point.
/// 2. **Matrix extraction**: Stamps the AC model at `ω = 1` to obtain
///    the conductance matrix `G` (real parts) and susceptance matrix `C`
///    (imaginary parts) from the complex MNA equation `(G + sC)x = 0`.
/// 3. **Pole computation**: Solves the generalized eigenvalue problem
///    `G·v = λ·C·v` using LAPACK's QZ algorithm. Poles are `s = −λ`.
/// 4. **Zero computation**: Builds the Rosenbrock system pencil from
///    `G`, `C`, the input vector, and the output vector.
/// 5. **DC gain**: Solves the linearized DC system with the unit excitation.
public struct PoleZeroAnalysis: Analysis, Sendable {

    public typealias Result = PoleZeroResult

    /// The small-signal input port.
    public let input: PoleZeroInput

    /// The positive output node.
    public let outputPositiveNode: Node

    /// The output reference node.
    public let outputReferenceNode: Node

    /// DC convergence configuration.
    public let dcConfig: ConvergenceConfig

    public init(
        outputNode: Node,
        inputSourceName: String,
        dcConfig: ConvergenceConfig = ConvergenceConfig()
    ) {
        self.input = .voltageSource(name: inputSourceName)
        self.outputPositiveNode = outputNode
        self.outputReferenceNode = .ground
        self.dcConfig = dcConfig
    }

    public init(
        input: PoleZeroInput,
        outputPositiveNode: Node,
        outputReferenceNode: Node = .ground,
        dcConfig: ConvergenceConfig = ConvergenceConfig()
    ) {
        self.input = input
        self.outputPositiveNode = outputPositiveNode
        self.outputReferenceNode = outputReferenceNode
        self.dcConfig = dcConfig
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

            let inputVector = try makeInputVector(plan: plan, dimension: dim)
            let outputVector = try makeOutputVector(plan: plan, dimension: dim)

            // Phase 2: Extract G and C dense matrices from AC stamps at ω = 1
            let (gDense, cDense) = try extractGCMatrices(
                plan: plan,
                devices: devices,
                dcState: dcState,
                dim: dim,
                variableMap: variableMap
            )

            // Phase 3: DC gain from the G matrix (s=0 response)
            let dcGain = try computeDCGainFromG(
                gDense: gDense,
                dim: dim,
                inputVector: inputVector,
                outputVector: outputVector
            )

            await observer?.emit(.progressUpdate(try ProgressInfo(
                id: analysisID,
                fraction: 0.3,
                message: "Computing poles"
            )))

            // Phase 4: Poles — solve G·v = λ·C·v, then s = −λ
            let gColMajor = toColumnMajor(gDense, dim: dim)
            let cColMajor = toColumnMajor(cDense, dim: dim)

            let poleResult = try GeneralizedEigenSolver.solve(
                matrixA: gColMajor,
                matrixB: cColMajor,
                dimension: dim
            )

            let poles = poleResult.eigenvalues.map { lambda in
                ComplexPair(real: -lambda.real, imag: -lambda.imag)
            }

            await observer?.emit(.progressUpdate(try ProgressInfo(
                id: analysisID,
                fraction: 0.7,
                message: "Computing zeros"
            )))

            let zeroPencil = makeZeroPencil(
                gDense: gDense,
                cDense: cDense,
                inputVector: inputVector,
                outputVector: outputVector,
                dimension: dim
            )
            let zeroResult = try GeneralizedEigenSolver.solve(
                matrixA: zeroPencil.a,
                matrixB: zeroPencil.b,
                dimension: dim + 1
            )
            let zeros = zeroResult.eigenvalues.map { lambda in
                ComplexPair(real: -lambda.real, imag: -lambda.imag)
            }

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .pz,
                status: .completed,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            return try PoleZeroResult(
                poles: poles,
                zeros: zeros,
                dcGain: dcGain,
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
        variableMap: [MNAVariable: Int]
    ) throws -> (g: [[Double]], c: [[Double]]) {
        var matrix = ComplexSparseMatrix(structure: plan.matrixStructure)

        var stamper = ComplexMatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, col, re, im in
                matrix.addValue(row: row, col: col, value: ComplexPair(real: re, imag: im))
            },
            stampRHS: { _, _, _ in
                // RHS not needed for G/C extraction
            }
        )

        // Stamp at ω = 1 so that imaginary parts equal the C coefficients
        let omega = 1.0
        for device in devices {
            device.stampAC(into: &stamper, state: dcState, omega: omega)
        }
        guard matrix.structuralMisses.isEmpty else {
            let first = matrix.structuralMisses[0]
            throw AnalysisError.internalError(
                "Pole-zero AC stamp missed matrix position (\(first.row), \(first.col))"
            )
        }

        let dense = matrix.toDense()

        // Separate real (G) and imaginary (C) parts
        var g = Array(repeating: Array(repeating: 0.0, count: dim), count: dim)
        var c = Array(repeating: Array(repeating: 0.0, count: dim), count: dim)

        for i in 0..<dim {
            for j in 0..<dim {
                g[i][j] = dense[i][j].real
                c[i][j] = dense[i][j].imag
                guard g[i][j].isFinite, c[i][j].isFinite else {
                    throw AnalysisError.internalError(
                        "Pole-zero matrix contains a non-finite value at (\(i), \(j))"
                    )
                }
            }
        }

        return (g, c)
    }

    /// Computes the DC gain by solving `G * x = b` using LAPACK's `dgesv`.
    ///
    /// At DC (`s = 0`) the system reduces to `G * x = b` where `b` has a
    /// unit voltage excitation at the input source branch row. The DC gain
    /// is the output node voltage from the resulting solution vector.
    private func computeDCGainFromG(
        gDense: [[Double]],
        dim: Int,
        inputVector: [Double],
        outputVector: [Double]
    ) throws -> Double {
        guard dim > 0 else {
            throw AnalysisError.invalidConfiguration(
                "Pole-zero analysis requires a non-empty MNA system"
            )
        }

        // Convert G to column-major flat array for LAPACK
        var a = toColumnMajor(gDense, dim: dim)

        var b = inputVector

        let dimension = CoreSpiceLAPACKInteger(dim)
        var ipiv = [CoreSpiceLAPACKInteger](repeating: 0, count: dim)
        let info = coreSpiceLAPACKSolve(
            dimension,
            1,
            &a,
            dimension,
            &ipiv,
            &b,
            dimension
        )

        if info > 0 {
            throw AnalysisError.singularMatrix
        }
        if info < 0 {
            throw AnalysisError.internalError(
                "LAPACK dgesv rejected argument \(-info) while computing pole-zero DC gain"
            )
        }

        return zip(outputVector, b).reduce(into: 0.0) {
            $0 += $1.0 * $1.1
        }
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

    /// Converts a row-major 2D array to a column-major flat array for LAPACK.
    private func toColumnMajor(_ matrix: [[Double]], dim: Int) -> [Double] {
        var colMajor = [Double](repeating: 0, count: dim * dim)
        for row in 0..<dim {
            for col in 0..<dim {
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
        dimension: Int
    ) -> (a: [Double], b: [Double]) {
        let augmentedDimension = dimension + 1
        var a = [Double](
            repeating: 0.0,
            count: augmentedDimension * augmentedDimension
        )
        var b = a
        for row in 0..<dimension {
            for column in 0..<dimension {
                a[column * augmentedDimension + row] = gDense[row][column]
                b[column * augmentedDimension + row] = cDense[row][column]
            }
            a[dimension * augmentedDimension + row] = -inputVector[row]
            a[row * augmentedDimension + dimension] = outputVector[row]
        }
        return (a, b)
    }
}

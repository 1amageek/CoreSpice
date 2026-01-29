import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent
import Synchronization
import Foundation
import Accelerate

/// Pole-zero (.pz) analysis.
///
/// Computes the poles and zeros of a circuit transfer function
/// `H(s) = V_out(s) / V_in(s)` from an input voltage source to
/// an output node. The analysis proceeds as follows:
///
/// 1. **DC operating point**: Finds the linearization point.
/// 2. **Matrix extraction**: Stamps the AC model at `ω = 1` to obtain
///    the conductance matrix `G` (real parts) and susceptance matrix `C`
///    (imaginary parts) from the complex MNA equation `(G + sC)x = 0`.
/// 3. **Pole computation**: Solves the generalized eigenvalue problem
///    `G·v = λ·C·v` using LAPACK's QZ algorithm. Poles are `s = −λ`.
/// 4. **Zero computation**: Deletes the output row and input column
///    from `G` and `C` to form submatrices, then solves the resulting
///    generalized eigenvalue problem. Zeros are `s = −λ`.
/// 5. **DC gain**: Solves the linearized DC system with unit excitation
///    at the input source.
public struct PoleZeroAnalysis: Analysis, Sendable {

    public typealias Result = PoleZeroResult

    /// The output node for the transfer function.
    public let outputNode: Node

    /// The name of the input voltage source (e.g., "V1").
    public let inputSourceName: String

    /// DC convergence configuration.
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
    ) async throws -> PoleZeroResult {
        let analysisID = AnalysisID()
        let startTimestamp = Timestamp()
        let dim = plan.topology.dimension
        let variableMap = plan.topology.variableMap

        observer?.emit(.analysisStarted(AnalysisStartedInfo(
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

            // Locate input source branch and output node in the variable map
            let inputBranchIndex = try findInputSourceBranchIndex(plan: plan)
            guard let outputNodeIndex = variableMap[.nodeVoltage(outputNode)] else {
                throw AnalysisError.invalidConfiguration(
                    "Output node \(outputNode.id) not found in variable map"
                )
            }

            // Phase 2: Extract G and C dense matrices from AC stamps at ω = 1
            let (gDense, cDense) = extractGCMatrices(
                plan: plan,
                devices: devices,
                dcState: dcState,
                dim: dim,
                variableMap: variableMap
            )

            // Phase 3: DC gain from the G matrix (s=0 response)
            let dcGain = computeDCGainFromG(
                gDense: gDense,
                dim: dim,
                inputBranchIndex: inputBranchIndex,
                outputNodeIndex: outputNodeIndex
            )

            observer?.emit(.progressUpdate(ProgressInfo(
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

            observer?.emit(.progressUpdate(ProgressInfo(
                id: analysisID,
                fraction: 0.7,
                message: "Computing zeros"
            )))

            // Phase 5: Zeros — eigenvalues of submatrix with output row
            //   and input column removed
            let subDim = dim - 1
            var zeros: [ComplexPair] = []
            if subDim > 0 {
                let gSub = extractSubmatrix(
                    gDense, dim: dim,
                    deleteRow: outputNodeIndex, deleteCol: inputBranchIndex
                )
                let cSub = extractSubmatrix(
                    cDense, dim: dim,
                    deleteRow: outputNodeIndex, deleteCol: inputBranchIndex
                )

                let gSubColMajor = toColumnMajor(gSub, dim: subDim)
                let cSubColMajor = toColumnMajor(cSub, dim: subDim)

                let zeroResult = try GeneralizedEigenSolver.solve(
                    matrixA: gSubColMajor,
                    matrixB: cSubColMajor,
                    dimension: subDim
                )

                zeros = zeroResult.eigenvalues.map { lambda in
                    ComplexPair(real: -lambda.real, imag: -lambda.imag)
                }
            }

            observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .pz,
                status: .completed,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            return PoleZeroResult(
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

            observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .pz,
                status: status,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
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
    ) -> (g: [[Double]], c: [[Double]]) {
        let matrixStorage = Mutex(ComplexSparseMatrix(structure: plan.matrixStructure))
        let rhsStorage = Mutex([ComplexPair](repeating: ComplexPair(), count: dim))

        var stamper = ComplexMatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, col, re, im in
                matrixStorage.withLock {
                    $0.addValue(row: row, col: col, value: ComplexPair(real: re, imag: im))
                }
            },
            stampRHS: { row, re, im in
                rhsStorage.withLock { rhs in
                    rhs[row] = ComplexPair(
                        real: rhs[row].real + re,
                        imag: rhs[row].imag + im
                    )
                }
            }
        )

        // Stamp at ω = 1 so that imaginary parts equal the C coefficients
        let omega = 1.0
        for device in devices {
            device.stampAC(into: &stamper, state: dcState, omega: omega)
        }

        let complexMatrix = matrixStorage.withLock { $0 }
        let dense = complexMatrix.toDense()

        // Separate real (G) and imaginary (C) parts
        var g = Array(repeating: Array(repeating: 0.0, count: dim), count: dim)
        var c = Array(repeating: Array(repeating: 0.0, count: dim), count: dim)

        for i in 0..<dim {
            for j in 0..<dim {
                g[i][j] = dense[i][j].real
                c[i][j] = dense[i][j].imag
            }
        }

        return (g, c)
    }

    /// Computes the DC gain by solving `G * x = b` using LAPACK's `dgesv_`.
    ///
    /// At DC (`s = 0`) the system reduces to `G * x = b` where `b` has a
    /// unit voltage excitation at the input source branch row. The DC gain
    /// is the output node voltage from the resulting solution vector.
    private func computeDCGainFromG(
        gDense: [[Double]],
        dim: Int,
        inputBranchIndex: Int,
        outputNodeIndex: Int
    ) -> Double {
        guard dim > 0 else { return 0.0 }

        // Convert G to column-major flat array for LAPACK
        var a = toColumnMajor(gDense, dim: dim)

        // RHS: unit excitation at the input source branch row
        var b = [Double](repeating: 0.0, count: dim)
        b[inputBranchIndex] = 1.0

        var n = __CLPK_integer(dim)
        var nrhs: __CLPK_integer = 1
        var lda = n
        var ldb = n
        var ipiv = [__CLPK_integer](repeating: 0, count: dim)
        var info: __CLPK_integer = 0

        dgesv_(&n, &nrhs, &a, &lda, &ipiv, &b, &ldb, &info)

        guard info == 0 else { return 0.0 }

        return b[outputNodeIndex]
    }

    /// Finds the matrix index of the input voltage source branch variable.
    private func findInputSourceBranchIndex(plan: ExecutionPlan) throws -> Int {
        let variableMap = plan.topology.variableMap

        let branchAllocatingTypes: Set<String> = [
            "vsource", "inductor", "vcvs", "ccvs", "cccs"
        ]

        var branchID = 0
        for instance in plan.ir.instances {
            guard branchAllocatingTypes.contains(instance.typeName) else { continue }

            if instance.name == inputSourceName {
                let branch = Branch(id: branchID)
                guard let index = variableMap[.branchCurrent(branch)] else {
                    throw AnalysisError.invalidConfiguration(
                        "Branch for input source '\(inputSourceName)' not found in variable map"
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
            "Input source '\(inputSourceName)' not found in circuit"
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

    /// Extracts a submatrix by deleting one row and one column.
    private func extractSubmatrix(
        _ matrix: [[Double]],
        dim: Int,
        deleteRow: Int,
        deleteCol: Int
    ) -> [[Double]] {
        let newDim = dim - 1
        var sub = Array(repeating: Array(repeating: 0.0, count: newDim), count: newDim)

        var si = 0
        for i in 0..<dim {
            if i == deleteRow { continue }
            var sj = 0
            for j in 0..<dim {
                if j == deleteCol { continue }
                sub[si][sj] = matrix[i][j]
                sj += 1
            }
            si += 1
        }

        return sub
    }
}

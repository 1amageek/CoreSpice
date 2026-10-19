import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceAnalysis
import CoreSpiceOSDI
import CoreSpiceEvent
import CoreSpiceParsedIR

/// Combines original device equations; Newton matrix/RHS never define physical acceptance.
internal struct NativeOSDIPhysicalValidator: DCPhysicalResidualValidating {
    let contributors: [any DCPhysicalResidualContributing]
    let rows: [DCEquationRowPolicy]
    let cancellation: CancellationToken
    let workspace: NativePhysicalResidualWorkspace
    var prior: (any DCPhysicalResidualValidating)? = nil

    init(contributors: [any DCPhysicalResidualContributing], rows: [DCEquationRowPolicy],
         cancellation: CancellationToken, prior: (any DCPhysicalResidualValidating)? = nil) {
        self.contributors = contributors; self.rows = rows; self.cancellation = cancellation; self.prior = prior
        workspace = NativePhysicalResidualWorkspace(count: rows.count)
    }

    func validate(state: SolutionState) throws {
        try prior?.validate(state: state)
        try Self.validate(state: state, rows: rows, cancellation: cancellation, workspace: workspace) { add in
            for contributor in contributors { try contributor.accumulatePhysicalResidual(state: state, add: add) }
        }
    }

    static func validate(state: SolutionState, rows: [DCEquationRowPolicy], cancellation: CancellationToken,
                         workspace: NativePhysicalResidualWorkspace, accumulate: ((Int, Double) -> Void) throws -> Void) throws {
        try NativeCircuitExecution.check(cancellation)
        guard state.variables.count == rows.count, state.variables.allSatisfy(\.isFinite) else { throw OSDIAdapterFailure.nonfiniteEvaluation }
        try workspace.withBuffers { buffers in
            var invalid = false
            try accumulate { row, value in
                    guard buffers.sums.indices.contains(row), value.isFinite else { invalid = true; return }
                    let sum = buffers.sums[row], next = sum + value
                    let correction = abs(sum) >= abs(value) ? (sum - next) + value : (value - next) + sum
                    buffers.sums[row] = next; buffers.corrections[row] += correction
                    if !next.isFinite || !buffers.corrections[row].isFinite { invalid = true }
            }
            guard !invalid else { throw OSDIAdapterFailure.nonfiniteEvaluation }
            for index in rows.indices {
                let residual = buffers.sums[index] + buffers.corrections[index]
                guard residual.isFinite else { throw OSDIAdapterFailure.nonfiniteEvaluation }
                guard abs(residual) <= rows[index].equationAbsoluteTolerance else {
                    throw SPICEOSDIPhysicalResidualFailure(row: index, kind: rows[index].kind,
                        residual: residual, absoluteTolerance: rows[index].equationAbsoluteTolerance)
                }
            }
            try NativeCircuitExecution.check(cancellation)
        }
    }

    static func policy(record: NativeCircuitPreparationRecord, config: ConvergenceConfig) throws -> DCEquationPolicy {
        guard let inputs = record.osdiRuntimeInputs else { throw OSDIAdapterFailure.conditionsMismatch }
        var rows = [DCEquationRowPolicy?](repeating: nil, count: record.plan.topology.dimension)
        for (variable, index) in record.plan.topology.variableMap {
            let kind = record.osdiVariableKinds[variable] ?? {
                if case .branchCurrent = variable { return OSDIVariableKind.electricalFlow }
                return OSDIVariableKind.electricalPotential
            }()
            switch kind {
            case .electricalPotential:
                rows[index] = try .init(kind: .electricalPotential, variableAbsoluteTolerance: config.vntol, equationAbsoluteTolerance: config.abstol)
            case .electricalFlow:
                rows[index] = try .init(kind: .electricalFlow, variableAbsoluteTolerance: config.abstol, equationAbsoluteTolerance: config.vntol)
            case .thermalPotential:
                rows[index] = try .init(kind: .thermalPotential, variableAbsoluteTolerance: inputs.tolerances.temperatureAbsoluteKelvin,
                    equationAbsoluteTolerance: inputs.tolerances.thermalResidualAbsoluteWatts)
            }
        }
        return try DCEquationPolicy(rows: rows.map { row in
            guard let row else { throw OSDIAdapterFailure.invalidMatrixMapping }; return row
        })
    }
}

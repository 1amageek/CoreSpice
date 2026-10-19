import CoreSpiceIR

/// An explicit unit-aware policy indexed by compiled global matrix row.
public struct DCEquationPolicy: Sendable {
    public let rows: [DCEquationRowPolicy]

    public init(rows: [DCEquationRowPolicy]) throws {
        guard !rows.isEmpty else {
            throw DCEquationPolicyError.invalidVariableMap
        }
        self.rows = rows
    }

    func validate(dimension: Int, variableMap: [MNAVariable: Int], config: ConvergenceConfig) throws {
        guard rows.count == dimension else {
            throw DCEquationPolicyError.dimensionMismatch(expected: dimension, actual: rows.count)
        }
        guard variableMap.count == dimension, Set(variableMap.values).count == dimension,
              variableMap.values.allSatisfy({ $0 >= 0 && $0 < dimension }) else {
            throw DCEquationPolicyError.invalidVariableMap
        }
        for (variable, index) in variableMap {
            switch (variable, rows[index].kind) {
            case (.branchCurrent, .electricalFlow), (.nodeVoltage, .electricalPotential),
                 (.nodeVoltage, .thermalPotential): break
            default: throw DCEquationPolicyError.variableKindMismatch(row: index)
            }
        }
        guard config.reltol.isFinite, config.reltol >= 0,
              config.gmin.isFinite, config.gmin >= 0, config.maxIterations > 0,
              config.minDamping.isFinite, config.minDamping > 0, config.minDamping <= 1 else {
            throw AnalysisError.invalidConfiguration("Explicit DC convergence requires finite nonnegative reltol/gmin, positive iterations and damping in (0, 1]")
        }
    }

    func requireElectricalEndpoint(_ node: Node, variableMap: [MNAVariable: Int], context: String) throws {
        if node == .ground { return }
        guard let index = variableMap[.nodeVoltage(node)], rows.indices.contains(index) else {
            throw AnalysisError.invalidConfiguration("\(context) endpoint is absent from the equation policy")
        }
        guard rows[index].kind == .electricalPotential else {
            throw AnalysisError.invalidConfiguration("\(context) requires electrical-potential endpoints")
        }
    }

    func isConverged(previous: [Double], current: [Double], relativeTolerance: Double) throws -> Bool {
        for index in current.indices {
            let tolerance = rows[index].variableAbsoluteTolerance + relativeTolerance * abs(current[index])
            guard tolerance.isFinite else {
                throw AnalysisError.invalidConfiguration("Explicit DC update tolerance overflowed")
            }
            if abs(current[index] - previous[index]) > tolerance { return false }
        }
        return true
    }
}

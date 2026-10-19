import CoreSpiceCompile
import Foundation

/// Original-equation checks and port transforms share the production Swift complex solver.
enum NetworkParameterTransforms {
    /// Corrects the original equations using stored factors; the unchanged residual gate owns acceptance.
    static func solveChecked(matrix: ComplexSparseMatrix, rhs: [ComplexPair],
                             solver: inout ComplexSparseLUSolver, solution: inout [ComplexPair],
                             residualBuffer: inout [ComplexPair], correctionBuffer: inout [ComplexPair],
                             tolerance: Double, control: NetworkParameterControl) throws -> Double {
        try control.checkCancellation()
        try solver.solve(rhs: rhs, into: &solution)
        while true {
            do {
                return try residual(matrix: matrix, rhs: rhs, solution: solution,
                    tolerance: tolerance, control: control)
            } catch let failure as NetworkParameterError {
                guard case .residualExceeded = failure else { throw failure }
                try control.checkCancellation()
                // The existing finite cumulative ceilings bound corrections, including a nonconverging sequence.
                try control.budget.beginRefinementSolve(complex: true)
                try control.checkpoint(workUnits: TransientExecutionBudget.add(
                    TransientExecutionBudget.multiply(matrix.structure.nonZeroCount, 24, "network correction product"),
                    TransientExecutionBudget.multiply(matrix.dimension, 16, "network correction vectors"),
                    "network correction work"))
                try matrix.multiply(vector: solution, into: &residualBuffer)
                for row in rhs.indices {
                    try control.checkCancellation()
                    residualBuffer[row] = rhs[row] - residualBuffer[row]
                    guard residualBuffer[row].real.isFinite, residualBuffer[row].imag.isFinite else {
                        throw NetworkParameterError.nonFinite("original equation correction RHS")
                    }
                }
                try solver.solve(rhs: residualBuffer, into: &correctionBuffer)
                var changed = false
                for row in solution.indices {
                    try control.checkCancellation()
                    let candidate = solution[row] + correctionBuffer[row]
                    guard candidate.real.isFinite, candidate.imag.isFinite else {
                        throw NetworkParameterError.nonFinite("original equation correction")
                    }
                    changed = changed || candidate.real.bitPattern != solution[row].real.bitPattern
                        || candidate.imag.bitPattern != solution[row].imag.bitPattern
                    solution[row] = candidate
                }
                if !changed { throw failure }
            }
        }
    }

    static func residual(matrix: ComplexSparseMatrix, rhs: [ComplexPair], solution: [ComplexPair],
                         tolerance: Double, control: NetworkParameterControl) throws -> Double {
        try control.checkpoint(workUnits: TransientExecutionBudget.add(
            TransientExecutionBudget.multiply(matrix.structure.nonZeroCount, 24, "network residual work"),
            TransientExecutionBudget.multiply(matrix.dimension, 16, "network residual rows"), "network residual work"))
        var maximum = 0.0
        for row in 0..<matrix.dimension {
            try control.checkCancellation()
            var sum = ComplexPair.zero
            var scale = rhs[row].magnitude
            for index in matrix.structure.rowPointers[row]..<matrix.structure.rowPointers[row + 1] {
                let value = matrix.values[index]
                let x = solution[matrix.structure.columnIndices[index]]
                sum = sum + value * x
                scale += value.magnitude * x.magnitude
            }
            let defect = (sum - rhs[row]).magnitude
            guard scale.isFinite, defect.isFinite else {
                throw NetworkParameterError.nonFinite("original matrix residual")
            }
            let ratio = scale == 0 ? (defect == 0 ? 0 : Double.infinity) : defect / scale
            guard ratio.isFinite, ratio <= tolerance else {
                throw NetworkParameterError.residualExceeded(row: row, value: ratio, limit: tolerance)
            }
            maximum = max(maximum, ratio)
        }
        return maximum
    }

    static func convert(y: NetworkParameterMatrix, ports: [NetworkPort], tolerance: Double,
                        control: NetworkParameterControl) throws
        -> (s: NetworkParameterMatrix, z: NetworkImpedanceParameters, residual: Double) {
        let n = y.portCount
        let square = y.values.count
        try control.checkpoint(workUnits: TransientExecutionBudget.multiply(square, 16, "network normalization"))
        var rows = [Int]()
        var columns = [Int]()
        rows.reserveCapacity(n + 1); columns.reserveCapacity(square)
        for row in 0..<n {
            rows.append(row * n)
            for column in 0..<n { columns.append(column) }
        }
        rows.append(square)
        let structure = try SparseStructure(dimension: n, rowPointers: rows, columnIndices: columns)
        var normalized = [ComplexPair](repeating: .zero, count: square)
        for row in 0..<n {
            let rowScale = sqrt(ports[row].referenceImpedance)
            for column in 0..<n {
                let columnReference = ports[column].referenceImpedance
                // Preserve exact equal-reference scaling, including singular normalization boundaries.
                let scale = ports[row].referenceImpedance == columnReference
                    ? columnReference : rowScale * sqrt(columnReference)
                let value = y.values[row * n + column] * ComplexPair(real: scale)
                guard value.real.isFinite, value.imag.isFinite else {
                    throw NetworkParameterError.nonFinite("reference-normalized admittance")
                }
                normalized[row * n + column] = value
            }
        }
        var scatteringSystem = ComplexSparseMatrix(structure: structure)
        for index in 0..<square {
            scatteringSystem.addValueDirect(at: index,
                value: normalized[index] + (index / n == index % n ? .one : .zero))
        }
        let scattering: [ComplexPair]
        var maximum = 0.0
        do {
            scattering = try solveColumns(matrix: scatteringSystem, tolerance: tolerance,
                control: control, maximumResidual: &maximum) { row, column in
                (row == column ? ComplexPair.one : .zero) - normalized[row * n + column]
            }
        } catch CompileError.singularMatrix {
            throw NetworkParameterError.singularScatteringTransform
        }
        var admittanceSystem = ComplexSparseMatrix(structure: structure)
        for index in 0..<square { admittanceSystem.addValueDirect(at: index, value: y.values[index]) }
        let impedance: NetworkImpedanceParameters
        do {
            let inverse = try solveColumns(matrix: admittanceSystem, tolerance: tolerance,
                control: control, maximumResidual: &maximum) { row, column in row == column ? .one : .zero }
            impedance = .defined(try NetworkParameterMatrix(portCount: n, values: inverse))
        } catch CompileError.singularMatrix {
            impedance = .undefined(.singularAdmittance)
        }
        return (try NetworkParameterMatrix(portCount: n, values: scattering), impedance, maximum)
    }

    private static func solveColumns(matrix: ComplexSparseMatrix, tolerance: Double,
                                     control: NetworkParameterControl, maximumResidual: inout Double,
                                     excitation: (Int, Int) -> ComplexPair) throws -> [ComplexPair] {
        let n = matrix.dimension
        try control.checkCancellation()
        try control.budget.beginLinearSolve(dimension: n, complex: true)
        var solver = ComplexSparseLUSolver(useAMDOrdering: false)
        try solver.configureExecution(control)
        try solver.factorize(matrix: matrix)
        var rhs = [ComplexPair](repeating: .zero, count: n)
        var solution = [ComplexPair](repeating: .zero, count: n)
        var residualBuffer = [ComplexPair](repeating: .zero, count: n)
        var correctionBuffer = [ComplexPair](repeating: .zero, count: n)
        var output = [ComplexPair](repeating: .zero, count: n * n)
        for column in 0..<n {
            try control.checkCancellation()
            if column > 0 { try control.budget.beginRefinementSolve(complex: true) }
            for row in 0..<n { rhs[row] = excitation(row, column) }
            maximumResidual = max(maximumResidual, try solveChecked(matrix: matrix, rhs: rhs,
                solver: &solver, solution: &solution, residualBuffer: &residualBuffer,
                correctionBuffer: &correctionBuffer, tolerance: tolerance, control: control))
            for row in 0..<n {
                guard solution[row].real.isFinite, solution[row].imag.isFinite else {
                    throw NetworkParameterError.nonFinite("network transform")
                }
                output[row * n + column] = solution[row]
            }
        }
        return output
    }
}

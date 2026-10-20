import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent

/// A sufficient interval-matrix regularity test, independent of inverse construction.
package enum ValidatedMatrixRegularity {
    package struct Limits: Sendable {
        package let maximumDimension: Int
        package let maximumMatrixNonzeros: Int
        package let maximumInverseNonzeros: Int
        package let maximumWorkspaceBytes: Int

        package init(maximumDimension: Int, maximumMatrixNonzeros: Int,
            maximumInverseNonzeros: Int, maximumWorkspaceBytes: Int) {
            self.maximumDimension = maximumDimension
            self.maximumMatrixNonzeros = maximumMatrixNonzeros
            self.maximumInverseNonzeros = maximumInverseNonzeros
            self.maximumWorkspaceBytes = maximumWorkspaceBytes
        }
    }

    package enum Failure: Error, Sendable, Equatable {
        case invalidInput
        case invalidCSR
        case nonFiniteInput
        case workspaceLimit
        case uncertified
    }

    /// A conditional numerical fact, without source, domain or physical-root authority.
    package struct Result: Sendable, Equatable {
        package let dimension: Int
        package let normUpperBound: Double

        fileprivate init(dimension: Int, normUpperBound: Double) {
            self.dimension = dimension
            self.normUpperBound = normUpperBound
        }
    }

    /// Borrows both immutable patterns and numeric spans for this synchronous call only.
    package static func certify(matrix: borrowing SparseStructure,
        values: Span<CompensatedEnclosure>, inverse: borrowing SparseStructure,
        inverseValues: Span<Double>, limits: Limits, budget: TransientExecutionBudget,
        storage: any AnalysisResultStorageAccounting, cancellation: CancellationToken) throws -> Result {
        let control = AnalysisLinearSolverControl(budget: budget, cancellation: cancellation, storage: storage)
        try control.checkpoint(workUnits: 0)
        guard matrix.dimension <= budget.limits.maximumMatrixDimension else { throw Failure.invalidInput }
        return try certify(matrix: matrix, values: values, inverse: inverse,
            inverseValues: inverseValues, limits: limits, control: control)
    }

    /// Uses the actual caller's retained mandatory resource owner, without a new budget.
    package static func certify(matrix: borrowing SparseStructure,
        values: Span<CompensatedEnclosure>, inverse: borrowing SparseStructure,
        inverseValues: Span<Double>, limits: Limits,
        control: any LinearSolverExecutionControlling) throws -> Result {
        try control.checkpoint(workUnits: 0)
        let n = matrix.dimension
        guard n > 0, n == inverse.dimension, limits.maximumDimension > 0,
              limits.maximumMatrixNonzeros >= 0, limits.maximumInverseNonzeros >= 0,
              limits.maximumWorkspaceBytes >= 0, n <= limits.maximumDimension,
              matrix.nonZeroCount <= limits.maximumMatrixNonzeros,
              inverse.nonZeroCount <= limits.maximumInverseNonzeros,
              values.count == matrix.nonZeroCount,
              inverseValues.count == inverse.nonZeroCount else { throw Failure.invalidInput }
        let bytes = try workspaceByteCount(dimension: n)
        guard bytes <= limits.maximumWorkspaceBytes else { throw Failure.workspaceLimit }
        try validate(matrix, control: control)
        try validate(inverse, control: control)
        for index in values.indices {
            try control.checkpoint(workUnits: 1)
            guard values[index].absoluteUpperBound.isFinite else { throw Failure.nonFiniteInput }
        }
        for index in inverseValues.indices {
            try control.checkpoint(workUnits: 1)
            guard inverseValues[index].isFinite else { throw Failure.nonFiniteInput }
        }
        let maximum = try withCertifiedResidualRows(matrix: matrix, values: values,
            inverse: inverse, inverseValues: inverseValues, byteCount: bytes, control: control) { _, _, _, _ in }
        return Result(dimension: n, normUpperBound: maximum)
    }

    /// Callers validate complete inputs first. Row spans expire before the accumulator resets.
    static func withCertifiedResidualRows(matrix: borrowing SparseStructure,
        values: Span<CompensatedEnclosure>, inverse: borrowing SparseStructure,
        inverseValues: Span<Double>, byteCount: Int,
        control: any LinearSolverExecutionControlling,
        consume: (Int, Span<CompensatedEnclosure>, Span<Int>, Int) throws -> Void) throws -> Double {
        let n = matrix.dimension
        let bytes = byteCount
        let zero = try CompensatedEnclosure(center: .zero)
        let one = try CompensatedEnclosure(center: .init(high: 1))
        let lease = try control.reserveStorage(byteCount: bytes)
        return try withExtendedLifetime(lease) {
            // Fixed initialized arrays belong to this call; none are returned or shared.
            try control.checkpoint(workUnits: TransientExecutionBudget.multiply(n, 3, "regularity initialization"))
            var accumulated = [CompensatedEnclosure](repeating: zero, count: n)
            var seen = [Bool](repeating: false, count: n)
            var touched = [Int](repeating: 0, count: n)
            var maximum = 0.0
            for row in 0..<n {
                try control.checkpoint(workUnits: 1)
                accumulated[row] = one
                seen[row] = true
                touched[0] = row
                var count = 1
                for ri in inverse.rowPointers[row]..<inverse.rowPointers[row + 1] {
                    try control.checkpoint(workUnits: 1)
                    let k = inverse.columnIndices[ri]
                    let coefficient = try CompensatedEnclosure(center: .init(high: inverseValues[ri]))
                    for mi in matrix.rowPointers[k]..<matrix.rowPointers[k + 1] {
                        // Structural products, including exact zero terms, consume work.
                        try control.checkpoint(workUnits: 1)
                        let column = matrix.columnIndices[mi]
                        if !seen[column] {
                            seen[column] = true
                            touched[count] = column
                            count += 1
                        }
                        accumulated[column] = try accumulated[column].subtracting(
                            coefficient.multiplied(by: values[mi]))
                    }
                }
                var rowBound = 0.0
                for index in 0..<count {
                    try control.checkpoint(workUnits: 1)
                    let bound = accumulated[touched[index]].absoluteUpperBound
                    guard bound.isFinite else { throw NumericalStateError.arithmeticOverflow }
                    rowBound = try addUp(rowBound, bound)
                    guard rowBound < 1 else { throw Failure.uncertified }
                }
                maximum = max(maximum, rowBound)
                try consume(row, accumulated.span, touched.span, count)
                for index in 0..<count {
                    try control.checkpoint(workUnits: 1)
                    let column = touched[index]
                    accumulated[column] = zero
                    seen[column] = false
                }
            }
            try control.checkpoint(workUnits: 0)
            return maximum
        }
    }

    /// Managed initialized payload plus Array values; allocator metadata is not included.
    static func workspaceByteCount(dimension: Int) throws -> Int {
        guard dimension > 0 else { throw Failure.invalidInput }
        var stride = try TransientExecutionBudget.add(MemoryLayout<CompensatedEnclosure>.stride,
            MemoryLayout<Bool>.stride, "regularity workspace stride")
        stride = try TransientExecutionBudget.add(stride, MemoryLayout<Int>.stride, "regularity workspace stride")
        let payload = try TransientExecutionBudget.multiply(dimension, stride, "regularity workspace bytes")
        var headers = try TransientExecutionBudget.add(MemoryLayout<[CompensatedEnclosure]>.stride,
            MemoryLayout<[Bool]>.stride, "regularity workspace headers")
        headers = try TransientExecutionBudget.add(headers, MemoryLayout<[Int]>.stride, "regularity workspace headers")
        return try TransientExecutionBudget.add(payload, headers, "regularity workspace bytes")
    }

    static func validate(_ pattern: borrowing SparseStructure,
        control: any LinearSolverExecutionControlling) throws {
        let expected = try TransientExecutionBudget.add(pattern.dimension, 1, "regularity row pointers")
        guard pattern.rowPointers.count == expected, pattern.rowPointers.first == 0,
              pattern.rowPointers.last == pattern.nonZeroCount else { throw Failure.invalidCSR }
        for row in 0..<pattern.dimension {
            try control.checkpoint(workUnits: 1)
            let start = pattern.rowPointers[row], end = pattern.rowPointers[row + 1]
            guard start >= 0, start <= end, end <= pattern.nonZeroCount else { throw Failure.invalidCSR }
            var previous = -1
            for index in start..<end {
                try control.checkpoint(workUnits: 1)
                let column = pattern.columnIndices[index]
                guard column > previous, column < pattern.dimension else { throw Failure.invalidCSR }
                previous = column
            }
        }
    }

    /// Each nonzero nonnegative sum is rounded upward, including gradual underflow.
    private static func addUp(_ a: Double, _ b: Double) throws -> Double {
        if a == 0 && b == 0 { return 0 }
        let sum = a + b
        guard sum.isFinite, sum.nextUp.isFinite else { throw NumericalStateError.arithmeticOverflow }
        return sum.nextUp
    }
}

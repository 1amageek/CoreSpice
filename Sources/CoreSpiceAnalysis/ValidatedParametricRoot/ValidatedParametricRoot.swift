import CoreSpiceCompile
import CoreSpiceDevices

/// A sufficient numerical Krawczyk test, conditional on the caller's actual H/J premises.
package enum ValidatedParametricRoot {
    package struct Limits: Sendable {
        package let maximumDimension: Int
        package let maximumJacobianNonzeros: Int
        package let maximumPreconditionerNonzeros: Int
        package let maximumWorkspaceBytes: Int
        package let maximumResultBytes: Int

        package init(maximumDimension: Int, maximumJacobianNonzeros: Int,
            maximumPreconditionerNonzeros: Int, maximumWorkspaceBytes: Int, maximumResultBytes: Int) {
            self.maximumDimension = maximumDimension
            self.maximumJacobianNonzeros = maximumJacobianNonzeros
            self.maximumPreconditionerNonzeros = maximumPreconditionerNonzeros
            self.maximumWorkspaceBytes = maximumWorkspaceBytes
            self.maximumResultBytes = maximumResultBytes
        }
    }

    package enum Failure: Error, Sendable, Equatable {
        case invalidInput
        case invalidCSR
        case nonFiniteInput
        case workspaceLimit
        case resultLimit
        case uncertified
    }

    /// Immutable conditional numerical data; it does not attest a source or physical chart.
    package final class Result: Sendable {
        package let dimension: Int
        package let normUpperBound: Double
        private let images: [CompensatedEnclosure]
        private let lease: any Sendable

        fileprivate init(image: [CompensatedEnclosure], normUpperBound: Double, lease: any Sendable) {
            dimension = image.count
            self.normUpperBound = normUpperBound
            images = image
            self.lease = lease
        }

        package func image(at index: Int) throws -> CompensatedEnclosure {
            guard images.indices.contains(index) else { throw Failure.invalidInput }
            return images[index]
        }
    }

    /// All patterns and spans are borrowed only for this synchronous operation.
    package static func certify(lower: borrowing Span<CompensatedValue>,
        upper: borrowing Span<CompensatedValue>, center: borrowing Span<CompensatedValue>,
        centerResidual: borrowing Span<CompensatedEnclosure>, jacobian: borrowing SparseStructure,
        jacobianValues: borrowing Span<CompensatedEnclosure>, preconditioner: borrowing SparseStructure,
        preconditionerValues: borrowing Span<Double>, limits: Limits,
        control: any LinearSolverExecutionControlling) throws -> Result {
        try control.checkpoint(workUnits: 0)
        let n = jacobian.dimension
        guard n > 0, n == preconditioner.dimension, lower.count == n, upper.count == n,
              center.count == n, centerResidual.count == n,
              limits.maximumDimension > 0, limits.maximumJacobianNonzeros >= 0,
              limits.maximumPreconditionerNonzeros >= 0, limits.maximumWorkspaceBytes >= 0,
              limits.maximumResultBytes >= 0, n <= limits.maximumDimension,
              jacobian.nonZeroCount <= limits.maximumJacobianNonzeros,
              preconditioner.nonZeroCount <= limits.maximumPreconditionerNonzeros,
              jacobianValues.count == jacobian.nonZeroCount,
              preconditionerValues.count == preconditioner.nonZeroCount else { throw Failure.invalidInput }
        let rowBytes = try ValidatedMatrixRegularity.workspaceByteCount(dimension: n)
        let deltaBytes = try enclosureArrayByteCount(n)
        let workspaceBytes = try add(rowBytes, deltaBytes)
        let resultBytes = try resultByteCount(dimension: n)
        guard workspaceBytes <= limits.maximumWorkspaceBytes else { throw Failure.workspaceLimit }
        guard resultBytes <= limits.maximumResultBytes else { throw Failure.resultLimit }
        do {
            try ValidatedMatrixRegularity.validate(jacobian, control: control)
            try ValidatedMatrixRegularity.validate(preconditioner, control: control)
        } catch ValidatedMatrixRegularity.Failure.invalidCSR { throw Failure.invalidCSR }
        for i in 0..<n {
            try control.checkpoint(workUnits: 1)
            guard ordered(lower[i], upper[i]), lower[i] != upper[i],
                  ordered(lower[i], center[i]), ordered(center[i], upper[i]) else { throw Failure.invalidInput }
            guard finiteBounds(lower[i]), finiteBounds(upper[i]), finiteBounds(center[i]),
                  centerResidual[i].absoluteUpperBound.isFinite else { throw Failure.nonFiniteInput }
        }
        for i in jacobianValues.indices {
            try control.checkpoint(workUnits: 1)
            guard jacobianValues[i].absoluteUpperBound.isFinite else { throw Failure.nonFiniteInput }
        }
        for i in preconditionerValues.indices {
            try control.checkpoint(workUnits: 1)
            guard preconditionerValues[i].isFinite else { throw Failure.nonFiniteInput }
        }
        let deltaLease = try control.reserveStorage(byteCount: deltaBytes)
        defer { withExtendedLifetime(deltaLease) {} }
        let resultLease = try control.reserveStorage(byteCount: resultBytes)
        let zero = try CompensatedEnclosure(center: .zero)
        try control.checkpoint(workUnits: n)
        var delta = [CompensatedEnclosure](repeating: zero, count: n)
        try control.checkpoint(workUnits: n)
        var image = [CompensatedEnclosure](repeating: zero, count: n)
        for i in 0..<n {
            try control.checkpoint(workUnits: 1)
            delta[i] = try displacement(lower: lower[i], upper: upper[i], center: center[i])
        }
        let norm: Double
        do {
            norm = try ValidatedMatrixRegularity.withCertifiedResidualRows(matrix: jacobian,
                values: jacobianValues, inverse: preconditioner, inverseValues: preconditionerValues,
                byteCount: rowBytes, control: control) { row, accumulated, touched, count in
                var value = try CompensatedEnclosure(center: center[row])
                for index in preconditioner.rowPointers[row]..<preconditioner.rowPointers[row + 1] {
                    try control.checkpoint(workUnits: 1)
                    let coefficient = try CompensatedEnclosure(center: .init(high: preconditionerValues[index]))
                    value = try value.subtracting(coefficient.multiplied(
                        by: centerResidual[preconditioner.columnIndices[index]]))
                }
                for index in 0..<count {
                    try control.checkpoint(workUnits: 1)
                    let column = touched[index]
                    value = try value.adding(accumulated[column].multiplied(by: delta[column]))
                }
                try control.checkpoint(workUnits: 2)
                guard value.absoluteUpperBound.isFinite else { throw NumericalStateError.arithmeticOverflow }
                let fromLower = try value.subtracting(.init(center: lower[row]))
                let toUpper = try CompensatedEnclosure(center: upper[row]).subtracting(value)
                guard try lowerBound(fromLower) > 0, try lowerBound(toUpper) > 0 else {
                    throw Failure.uncertified
                }
                image[row] = value
            }
        } catch ValidatedMatrixRegularity.Failure.uncertified { throw Failure.uncertified }
        // The result transfers the single image buffer, retaining its preadmitted payload.
        try control.checkpoint(workUnits: 4)
        try control.checkpoint(workUnits: 0)
        return Result(image: image, normUpperBound: norm, lease: resultLease)
    }

    /// Managed result fields and image payload, excluding allocator metadata/RSS.
    static func resultByteCount(dimension: Int) throws -> Int {
        guard dimension > 0 else { throw Failure.invalidInput }
        var bytes = try enclosureArrayByteCount(dimension)
        bytes = try add(bytes, MemoryLayout<Int>.stride)
        bytes = try add(bytes, MemoryLayout<Double>.stride)
        return try add(bytes, MemoryLayout<any Sendable>.stride)
    }

    static func workspaceByteCount(dimension: Int) throws -> Int {
        guard dimension > 0 else { throw Failure.invalidInput }
        return try add(ValidatedMatrixRegularity.workspaceByteCount(dimension: dimension),
            enclosureArrayByteCount(dimension))
    }

    private static func enclosureArrayByteCount(_ n: Int) throws -> Int {
        try add(TransientExecutionBudget.multiply(n, MemoryLayout<CompensatedEnclosure>.stride,
            "parametric root enclosure payload"), MemoryLayout<[CompensatedEnclosure]>.stride)
    }

    private static func add(_ a: Int, _ b: Int) throws -> Int {
        try TransientExecutionBudget.add(a, b, "parametric root capacity")
    }

    /// Normalized pairs are ordered by their exact high/low values, without a rounded sum.
    private static func ordered(_ a: CompensatedValue, _ b: CompensatedValue) -> Bool {
        a.high < b.high || (a.high == b.high && a.low <= b.low)
    }

    private static func finiteBounds(_ value: CompensatedValue) -> Bool {
        let bounds = value.bounds
        return bounds.lower.isFinite && bounds.upper.isFinite
    }

    private static func lowerBound(_ value: CompensatedEnclosure) throws -> Double {
        let bounds = value.center.bounds
        let lower = value.radius == 0 ? bounds.lower : (bounds.lower - value.radius).nextDown
        let upper = value.radius == 0 ? bounds.upper : (bounds.upper + value.radius).nextUp
        guard lower.isFinite, upper.isFinite else { throw NumericalStateError.arithmeticOverflow }
        return lower
    }

    /// Keep the original asymmetric interval; the chosen midpoint is merely an enclosure center.
    private static func displacement(lower: CompensatedValue, upper: CompensatedValue,
        center: CompensatedValue) throws -> CompensatedEnclosure {
        let lo = try CompensatedEnclosure(center: lower)
        let hi = try CompensatedEnclosure(center: upper)
        let half = try CompensatedEnclosure(center: .init(high: 0.5))
        let midpoint = try lo.multiplied(by: half).adding(hi.multiplied(by: half))
        // Discarding this calculation's radius selects an exact represented center, not a bound.
        // Both endpoint distances are independently bounded around that selected value below.
        let selected = try CompensatedEnclosure(center: midpoint.center)
        let radius = max(try lo.subtracting(selected).absoluteUpperBound,
            try hi.subtracting(selected).absoluteUpperBound)
        guard radius.isFinite else { throw NumericalStateError.arithmeticOverflow }
        let box = try CompensatedEnclosure(center: selected.center, radius: radius)
        let result = try box.subtracting(.init(center: center))
        guard result.absoluteUpperBound.isFinite else { throw NumericalStateError.arithmeticOverflow }
        return result
    }
}

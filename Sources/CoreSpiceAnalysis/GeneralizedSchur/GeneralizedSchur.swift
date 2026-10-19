import CoreSpiceCompile
import Foundation

/// Pure Swift real QZ, following Reference-LAPACK v3.12.1 (see THIRD_PARTY_NOTICES.txt).
enum GeneralizedSchur {
    static func decompose(matrixA: [Double], matrixB: [Double], dimension n: Int,
                          control: (any LinearSolverExecutionControlling)? = nil) throws
        -> GeneralizedSchurDecomposition {
        try control?.checkpoint(workUnits: 0)
        guard n > 0 else { throw GeneralizedSchurError.invalidDimension(n) }
        let (square, overflow) = n.multipliedReportingOverflow(by: n)
        guard !overflow else { throw GeneralizedSchurError.invalidDimension(n) }
        guard matrixA.count == square, matrixB.count == square else {
            throw GeneralizedSchurError.matrixSizeMismatch(expected: square,
                matrixA: matrixA.count, matrixB: matrixB.count)
        }
        let aExponent = try scalingExponent(matrixA, name: "A", control: control)
        let bExponent = try scalingExponent(matrixB, name: "B", control: control)
        // Four Schur planes, one residual plane, three homogeneous arrays and output entries.
        let (planes, planesOverflow) = square.multipliedReportingOverflow(by: 5)
        let (vectorPayload, vectorsOverflow) = n.multipliedReportingOverflow(by: 8)
        let (vectors, vectorTailOverflow) = vectorPayload.addingReportingOverflow(3)
        let (scalars, scalarsOverflow) = planes.addingReportingOverflow(vectors)
        let (bytes, bytesOverflow) = scalars.multipliedReportingOverflow(by: MemoryLayout<Double>.stride)
        let (payload, payloadOverflow) = bytes.addingReportingOverflow(16 * MemoryLayout<Array<Double>>.stride)
        guard !planesOverflow, !vectorsOverflow, !vectorTailOverflow, !scalarsOverflow, !bytesOverflow, !payloadOverflow else {
            throw GeneralizedSchurError.invalidDimension(n)
        }
        let lease = try control?.reserveStorage(byteCount: payload)
        // Includes identity/COW copies and all three length-(n+1) homogeneous vectors.
        try control?.checkpoint(workUnits: 2 * square + 3 * (n + 1))
        var work = try QZIteration(n: n, a: try scaled(matrixA, exponent: aExponent, control: control),
                               b: try scaled(matrixB, exponent: bExponent, control: control), control: control)
        try work.reduce()
        try work.iterate()
        var entries = [HomogeneousEigenvalue]()
        entries.reserveCapacity(n)
        for index in 1...n {
            try control?.checkpoint(workUnits: 24)
            try work.validateClassification(at: index)
            let entry = try restored(alphaReal: work.alphaReal[index], alphaImag: work.alphaImag[index],
                beta: work.beta[index], aExponent: aExponent, bExponent: bExponent)
            guard entry.alphaReal != 0 || entry.alphaImag != 0 || entry.beta != 0 else {
                throw GeneralizedSchurError.indeterminateEigenvalue(index: index - 1)
            }
            entries.append(entry)
        }
        try verify(matrixA, exponent: aExponent, schur: work.h, q: work.q, z: work.z, control: control)
        try verify(matrixB, exponent: bExponent, schur: work.t, q: work.q, z: work.z, control: control)
        try verifyOrthogonal(work.q, control: control)
        try verifyOrthogonal(work.z, control: control)
        try control?.checkpoint(workUnits: 0)
        return GeneralizedSchurDecomposition(s: work.h.values, t: work.t.values,
            q: work.q.values, z: work.z.values, aScaleExponent: aExponent, bScaleExponent: bExponent,
            eigenvalues: entries, sweepCount: work.sweeps, retainedWorkspace: lease)
    }

    private static func scalingExponent(_ values: [Double], name: String,
        control: (any LinearSolverExecutionControlling)?) throws -> Int {
        var maximum = 0.0
        for index in values.indices {
            if index % 32 == 0 { try control?.checkpoint(workUnits: min(32, values.count - index) * 2) }
            guard values[index].isFinite else {
                throw GeneralizedSchurError.nonFiniteMatrixValue(matrix: name, index: index)
            }
            maximum = max(maximum, abs(values[index]))
        }
        return maximum == 0 ? 0 : -maximum.exponent
    }

    private static func scaled(_ values: [Double], exponent: Int,
        control: (any LinearSolverExecutionControlling)?) throws -> [Double] {
        try control?.checkpoint(workUnits: values.count)
        var output = [Double](repeating: 0, count: values.count)
        for index in values.indices {
            if index % 32 == 0 { try control?.checkpoint(workUnits: min(32, values.count - index) * 2) }
            let value = Double(sign: values[index].sign, exponent: exponent, significand: abs(values[index]))
            guard value.isFinite else { throw GeneralizedSchurError.nonFiniteArithmetic }
            guard value != 0 || values[index] == 0 else { throw GeneralizedSchurError.scalingUnderflow }
            output[index] = value
        }
        return output
    }

    private static func restored(alphaReal: Double, alphaImag: Double, beta: Double,
                                 aExponent: Int, bExponent: Int) throws -> HomogeneousEigenvalue {
        guard alphaReal.isFinite, alphaImag.isFinite, beta.isFinite else {
            throw GeneralizedSchurError.nonFiniteArithmetic
        }
        // A common projective exponent preserves each nonzero component without overflow.
        var lower = Int.min, upper = Int.max
        for (value, exponent) in [(alphaReal, aExponent), (alphaImag, aExponent), (beta, bExponent)] {
            if value != 0 {
                let target = value.exponent - exponent
                lower = max(lower, target - 1023)
                upper = min(upper, target + 1074)
            }
        }
        guard lower <= upper else { throw GeneralizedSchurError.scalingUnderflow }
        let shift = max(lower, min(0, upper))
        func restore(_ value: Double, exponent: Int) throws -> Double {
            if value == 0 { return value }
            let result = Double(sign: value.sign, exponent: value.exponent - exponent - shift,
                                significand: abs(value.significand))
            guard result.isFinite else { throw GeneralizedSchurError.nonFiniteArithmetic }
            guard result != 0 else { throw GeneralizedSchurError.scalingUnderflow }
            return result
        }
        return try HomogeneousEigenvalue(alphaReal: restore(alphaReal, exponent: aExponent),
            alphaImag: restore(alphaImag, exponent: aExponent), beta: restore(beta, exponent: bExponent))
    }

    private static func verify(_ original: [Double], exponent: Int, schur: QZMatrix,
        q: QZMatrix, z: QZMatrix, control: (any LinearSolverExecutionControlling)?) throws {
        let n = schur.n
        try control?.checkpoint(workUnits: original.count)
        var intermediate = [Double](repeating: 0, count: original.count)
        var norm = 0.0, residual = 0.0
        for column in 1...n {
            for row in 1...n {
                var sum = 0.0
                for k in 1...n {
                    if (k - 1) % 32 == 0 { try control?.checkpoint(workUnits: min(32, n - k + 1) * 4) }
                    let value = original[(column - 1) * n + k - 1]
                    let scaled = Double(sign: value.sign, exponent: exponent, significand: abs(value))
                    sum = sum.addingProduct(q[k, row], scaled)
                }
                guard sum.isFinite else { throw GeneralizedSchurError.nonFiniteArithmetic }
                intermediate[(column - 1) * n + row - 1] = sum
                let value = original[(column - 1) * n + row - 1]
                norm = max(norm, abs(Double(sign: value.sign, exponent: exponent, significand: abs(value))))
            }
        }
        for column in 1...n {
            for row in 1...n {
                var sum = 0.0
                for k in 1...n {
                    if (k - 1) % 32 == 0 { try control?.checkpoint(workUnits: min(32, n - k + 1) * 2) }
                    sum = sum.addingProduct(intermediate[(k - 1) * n + row - 1], z[k, column])
                }
                guard sum.isFinite, schur[row, column].isFinite else { throw GeneralizedSchurError.nonFiniteArithmetic }
                residual = max(residual, abs(sum - schur[row, column]))
            }
        }
        // A numerical backward-error admission, independent of physical source tolerances.
        let bound = 128 * Double(n) * Double.ulpOfOne * max(norm, Double.leastNormalMagnitude)
        guard residual.isFinite, residual <= bound else { throw GeneralizedSchurError.invalidSchurQuality }
    }

    private static func verifyOrthogonal(_ matrix: QZMatrix,
        control: (any LinearSolverExecutionControlling)?) throws {
        let n = matrix.n
        var error = 0.0
        for j in 1...n {
            for i in 1...n {
                var product = 0.0
                for k in 1...n {
                    if (k - 1) % 32 == 0 { try control?.checkpoint(workUnits: min(32, n - k + 1) * 2) }
                    product = product.addingProduct(matrix[k, i], matrix[k, j])
                }
                guard product.isFinite else { throw GeneralizedSchurError.nonFiniteArithmetic }
                error = max(error, abs(product - (i == j ? 1 : 0)))
            }
        }
        guard error.isFinite, error <= 128 * Double(n) * Double.ulpOfOne else {
            throw GeneralizedSchurError.invalidSchurQuality
        }
    }
}

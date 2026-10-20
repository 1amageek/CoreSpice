import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent

/// Conditional inverse action using only the matched chart's retained checked preconditioner.
internal enum NativePrescribedVoltageEvolutionInverse {
    static func chargeStateLipschitzUpperBound(record: NativeCircuitPreparationRecord,
        chart: NativePrescribedVoltageChart, cancellation: CancellationToken) throws -> Double {
        let payload = try chart.evolutionPayload(record: record)
        func tick(_ units: Int = 1) throws {
            guard !cancellation.isCancelled, !Task.isCancelled else { throw NativeConstitutiveInspection.Failure.cancelled }
            try payload.control.checkpoint(workUnits: units)
        }
        try tick(0)
        let inverse = payload.inverse
        guard inverse.dimension == chart.dimension, payload.inverseValues.count == inverse.nonZeroCount else {
            throw NativePrescribedVoltageEvolutionFailure.invalidBinding
        }
        if payload.spatial.dynamicStaticNormUpperBound == 0 {
            try tick(6)
            return try lipschitzUpperBound(driftDerivativeNormUpperBound: 0,
                inverseNormUpperBound: 0, residualNormUpperBound: payload.root.normUpperBound)
        }
        var maximum = 0.0
        for row in 0..<inverse.dimension {
            try tick()
            var sum = 0.0
            for index in inverse.rowPointers[row]..<inverse.rowPointers[row + 1] {
                try tick(3)
                let magnitude = abs(payload.inverseValues[index])
                guard magnitude.isFinite else { throw NumericalStateError.arithmeticOverflow }
                if magnitude != 0 {
                    sum = (sum + magnitude).nextUp
                    guard sum.isFinite else { throw NumericalStateError.arithmeticOverflow }
                }
            }
            maximum = max(maximum, sum)
        }
        try tick(6)
        let result = try lipschitzUpperBound(driftDerivativeNormUpperBound: payload.spatial.dynamicStaticNormUpperBound,
            inverseNormUpperBound: maximum, residualNormUpperBound: payload.root.normUpperBound)
        try tick(0)
        return result
    }

    /// Directed scalar arithmetic only; detached numbers grant no source or chart authority.
    static func lipschitzUpperBound(driftDerivativeNormUpperBound k: Double,
        inverseNormUpperBound y: Double, residualNormUpperBound eta: Double) throws -> Double {
        guard k.isFinite, k >= 0, y.isFinite, y >= 0, eta.isFinite, eta >= 0, eta < 1 else {
            throw NativePrescribedVoltageEvolutionFailure.invalidInput
        }
        if k == 0 || y == 0 { return 0 }
        let denominator = eta == 0 ? 1 : (1 - eta).nextDown
        guard denominator.isFinite, denominator > 0 else { throw NumericalStateError.arithmeticOverflow }
        let numerator = (k * y).nextUp
        guard numerator.isFinite else { throw NumericalStateError.arithmeticOverflow }
        let result = (numerator / denominator).nextUp
        guard result.isFinite else { throw NumericalStateError.arithmeticOverflow }
        return result
    }

    static func enclose(record: NativeCircuitPreparationRecord, chart: NativePrescribedVoltageChart,
        rightHandSide: borrowing Span<CompensatedEnclosure>, into: inout MutableSpan<CompensatedEnclosure>,
        cancellation: CancellationToken) throws {
        let payload = try chart.evolutionPayload(record: record)
        let control = payload.control
        func tick(_ units: Int = 1) throws {
            guard !cancellation.isCancelled, !Task.isCancelled else { throw NativeConstitutiveInspection.Failure.cancelled }
            try control.checkpoint(workUnits: units)
        }
        try tick(0)
        let n = chart.dimension, inverse = payload.inverse
        let norm = payload.root.normUpperBound
        guard rightHandSide.count == n, into.count == n else { throw NativePrescribedVoltageEvolutionFailure.invalidInput }
        guard n > 0, inverse.dimension == n, payload.jacobian.dimension == n,
              payload.inverseValues.count == inverse.nonZeroCount,
              norm.isFinite, norm >= 0, norm < 1 else { throw NativePrescribedVoltageEvolutionFailure.invalidBinding }
        // Canonical CSR and every Y coefficient were checked when this immutable chart was created.
        for row in 0..<n {
            try tick()
            guard rightHandSide[row].absoluteUpperBound.isFinite else { throw NumericalStateError.arithmeticOverflow }
        }
        let zero = try CompensatedEnclosure(center: .zero)
        var maximum = 0.0
        for row in 0..<n {
            try tick()
            var value = zero
            for index in inverse.rowPointers[row]..<inverse.rowPointers[row + 1] {
                // Structural zero slots still consume the original request's work allowance.
                try tick()
                let coefficient = try CompensatedEnclosure(center: .init(high: payload.inverseValues[index]))
                value = try value.adding(coefficient.multiplied(by: rightHandSide[inverse.columnIndices[index]]))
            }
            let magnitude = value.absoluteUpperBound
            guard magnitude.isFinite else { throw NumericalStateError.arithmeticOverflow }
            maximum = max(maximum, magnitude)
            into[row] = value
        }
        // Admit the bounded six directed scalar operations before computing the tail.
        try tick(6)
        let tail = try tailUpperBound(normUpperBound: norm, maximumMagnitude: maximum)
        let error = try CompensatedEnclosure(center: .zero, radius: tail)
        for row in 0..<n {
            try tick()
            // A zero tail preserves W's existing enclosure exactly.
            if tail != 0 { into[row] = try into[row].adding(error) }
            guard into[row].absoluteUpperBound.isFinite else { throw NumericalStateError.arithmeticOverflow }
        }
        // The caller owns and publishes the complete Evolution only after all actions succeed.
        try tick(0)
    }

    /// Scalar arithmetic only: this function creates no chart, root or evolution certificate.
    static func tailUpperBound(normUpperBound q: Double, maximumMagnitude m: Double) throws -> Double {
        guard q.isFinite, q >= 0, q < 1, m.isFinite, m >= 0 else {
            throw NativePrescribedVoltageEvolutionFailure.invalidInput
        }
        if q == 0 || m == 0 { return 0 }
        let denominator = (1 - q).nextDown
        guard denominator.isFinite, denominator > 0 else { throw NumericalStateError.arithmeticOverflow }
        let quotient = q / denominator
        guard quotient.isFinite, quotient.nextUp.isFinite else { throw NumericalStateError.arithmeticOverflow }
        let factor = quotient.nextUp
        let product = factor * m
        guard product.isFinite, product.nextUp.isFinite else { throw NumericalStateError.arithmeticOverflow }
        // A positive real tail that rounds to zero is still bounded by the least subnormal.
        return product.nextUp
    }
}

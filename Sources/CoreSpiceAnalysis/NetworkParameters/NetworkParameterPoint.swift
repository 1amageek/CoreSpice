import CoreSpiceCompile
import CoreSpiceEvent
import Foundation

/// All observations at one positive frequency and one unchanged DC operating point.
public struct NetworkParameterPoint: Sendable {
    public let frequency: Double
    public let y: NetworkParameterMatrix
    public let s: NetworkParameterMatrix
    public let z: NetworkImpedanceParameters
    public let stability: TwoPortStability?
    /// Maximum rowwise backward residual across original circuit and transform solves.
    public let maximumBackwardResidual: Double

    /// Validates saved network mathematics only; this never creates source or operating-point evidence.
    /// Saved S/Z and metrics must reproduce exact bits under the current deterministic arithmetic.
    public static func validatingSaved(frequency: Double, y: NetworkParameterMatrix,
        s: NetworkParameterMatrix, z: NetworkImpedanceParameters, stability: TwoPortStability?,
        maximumBackwardResidual: Double, ports: [NetworkPort], limits: NetworkParameterLimits,
        resources: AnalysisExecutionResources, cancellation: CancellationToken) throws -> Self {
        try limits.validate()
        guard resources.limits == limits.executionLimits else {
            throw NetworkParameterError.invalidConfiguration("Saved network resource policy does not match declared execution limits")
        }
        guard !ports.isEmpty, ports.count <= limits.maximumPorts else {
            throw NetworkParameterError.invalidConfiguration("Saved network port count exceeds caller limits")
        }
        let square = try TransientExecutionBudget.multiply(ports.count, ports.count, "saved network entries")
        let budget = try resources.budget(dimension: ports.count, nonZeroCount: square, deviceCount: 0)
        return try validatingSaved(frequency: frequency, y: y, s: s, z: z, stability: stability,
            maximumBackwardResidual: maximumBackwardResidual, ports: ports, limits: limits,
            budget: budget, storage: nil, cancellation: cancellation)
    }

    /// Native reload shares its existing cumulative owner and capacity policy directly.
    package static func validatingSaved(frequency: Double, y: NetworkParameterMatrix,
        s: NetworkParameterMatrix, z: NetworkImpedanceParameters, stability: TwoPortStability?,
        maximumBackwardResidual: Double, ports: [NetworkPort], limits: NetworkParameterLimits,
        budget: TransientExecutionBudget, storage: (any AnalysisResultStorageAccounting)?,
        cancellation: CancellationToken) throws -> Self {
        try limits.validate()
        guard budget.limits == limits.executionLimits else {
            throw NetworkParameterError.invalidConfiguration("Saved network budget policy does not match declared execution limits")
        }
        let n = ports.count
        guard n > 0, n <= limits.maximumPorts, frequency.isFinite, frequency > 0,
              (2 * Double.pi * frequency).isFinite, y.portCount == n, s.portCount == n,
              maximumBackwardResidual.isFinite, maximumBackwardResidual >= 0,
              maximumBackwardResidual <= limits.residualTolerance else {
            throw NetworkParameterError.inconsistentSavedPoint("Frequency, shape or residual class")
        }
        if case .defined(let matrix) = z, matrix.portCount != n {
            throw NetworkParameterError.inconsistentSavedPoint("Impedance shape")
        }
        let control = NetworkParameterControl(maximumBytes: limits.maximumTemporaryBytes,
            budget: budget, cancellation: cancellation, upstream: storage)
        try control.checkCancellation()
        let square = try TransientExecutionBudget.multiply(n, n, "saved network entries")
        let scalarCount = try TransientExecutionBudget.add(
            TransientExecutionBudget.multiply(square, 6, "saved network scalars"), 16, "saved network metrics")
        try TransientExecutionBudget.admit(scalarCount, limit: limits.maximumResultScalars,
            resource: "network.resultScalars")
        let scratchScalars = try TransientExecutionBudget.add(
            TransientExecutionBudget.multiply(square, 32, "saved network transforms"),
            TransientExecutionBudget.multiply(n, 64, "saved network metadata"), "saved network scratch")
        let scratch = try control.reserveStorage(byteCount: TransientExecutionBudget.multiply(scratchScalars,
            MemoryLayout<Double>.stride, "saved network scratch bytes"))
        defer { withExtendedLifetime(scratch) {} }
        try control.checkpoint(workUnits: TransientExecutionBudget.multiply(n, n, "saved network port checks"))
        for index in ports.indices {
            try control.checkCancellation()
            let port = ports[index]
            guard !port.voltageSourceName.isEmpty, port.referenceImpedance.isFinite,
                  port.referenceImpedance > 0 else {
                throw NetworkParameterError.inconsistentSavedPoint("Port reference")
            }
            for earlier in 0..<index where ports[earlier].voltageSourceName.caseInsensitiveCompare(port.voltageSourceName) == .orderedSame {
                throw NetworkParameterError.inconsistentSavedPoint("Duplicate port source")
            }
        }
        let converted = try NetworkParameterTransforms.convert(y: y, ports: ports,
            tolerance: limits.residualTolerance, control: control)
        try control.checkpoint(workUnits: TransientExecutionBudget.multiply(square, 8, "saved network comparison"))
        guard try equalMatrixBits(s, converted.s, control: control),
              try equalImpedance(z, converted.z, control: control) else {
            throw NetworkParameterError.inconsistentSavedPoint("Saved S/Z does not reproduce from Y and references")
        }
        try control.checkpoint(workUnits: n == 2 ? 128 : 0)
        let expectedStability = n == 2 ? try TwoPortStability(scattering: converted.s) : nil
        guard equalStability(stability, expectedStability) else {
            throw NetworkParameterError.inconsistentSavedPoint("Saved pointwise stability does not reproduce")
        }
        guard maximumBackwardResidual >= converted.residual else {
            throw NetworkParameterError.inconsistentSavedPoint("Saved residual understates transform residual")
        }
        try control.checkCancellation()
        return Self(frequency: frequency, y: y, s: s, z: z, stability: stability,
            maximumBackwardResidual: maximumBackwardResidual)
    }

    private static func equalMatrixBits(_ first: NetworkParameterMatrix, _ second: NetworkParameterMatrix,
                                        control: NetworkParameterControl) throws -> Bool {
        guard first.portCount == second.portCount, first.values.count == second.values.count else { return false }
        for index in first.values.indices {
            if index % first.portCount == 0 { try control.checkCancellation() }
            if !equalComplexBits(first.values[index], second.values[index]) { return false }
        }
        return true
    }

    private static func equalComplexBits(_ first: ComplexPair, _ second: ComplexPair) -> Bool {
        first.real.bitPattern == second.real.bitPattern && first.imag.bitPattern == second.imag.bitPattern
    }

    private static func equalImpedance(_ first: NetworkImpedanceParameters, _ second: NetworkImpedanceParameters,
                                       control: NetworkParameterControl) throws -> Bool {
        switch (first, second) {
        case (.defined(let a), .defined(let b)): return try equalMatrixBits(a, b, control: control)
        case (.undefined(let a), .undefined(let b)): return a == b
        default: return false
        }
    }

    private static func equalMetric(_ first: TwoPortStability.Metric, _ second: TwoPortStability.Metric) -> Bool {
        switch (first, second) {
        case (.defined(let a), .defined(let b)): return a.bitPattern == b.bitPattern
        case (.undefined(let a), .undefined(let b)): return a == b
        default: return false
        }
    }

    private static func equalStability(_ first: TwoPortStability?, _ second: TwoPortStability?) -> Bool {
        switch (first, second) {
        case (nil, nil): return true
        case (.some(let a), .some(let b)):
            return equalComplexBits(a.delta, b.delta) && equalMetric(a.rollettK, b.rollettK)
                && equalMetric(a.mu, b.mu) && equalMetric(a.reverseMu, b.reverseMu)
                && a.satisfiesRollettInequalities == b.satisfiesRollettInequalities
        default: return false
        }
    }
}

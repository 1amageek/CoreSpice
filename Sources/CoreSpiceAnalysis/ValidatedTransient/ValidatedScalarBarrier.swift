import CoreSpiceDevices
import CoreSpiceEvent

/// A conditional scalar comparison test; it establishes no physical-model premise.
struct ValidatedScalarBarrier: Sendable {
    static let workUnits = 4_096

    let initialRadius: Double
    let slope: Double
    let duration: Double
    let contractionLowerBound: Double
    let forcingUpperBound: Double
    let endpointRadiusUpperBound: Double
    let maximumRadiusUpperBound: Double

    private init(initialRadius: Double, slope: Double, duration: Double,
        contractionLowerBound: Double, forcingUpperBound: Double,
        endpointRadiusUpperBound: Double) {
        self.initialRadius = initialRadius
        self.slope = slope
        self.duration = duration
        self.contractionLowerBound = contractionLowerBound
        self.forcingUpperBound = forcingUpperBound
        self.endpointRadiusUpperBound = endpointRadiusUpperBound
        self.maximumRadiusUpperBound = max(initialRadius, endpointRadiusUpperBound)
    }

    static func check(initialRadius: Double, slope: Double, duration: Double,
        contractionLowerBound alpha: Double, forcingUpperBound eta: Double,
        budget: TransientExecutionBudget, cancellation: CancellationToken) throws -> Self {
        guard !cancellation.isCancelled, !Task.isCancelled else { throw AnalysisError.cancelled }
        guard initialRadius.isFinite, initialRadius >= 0, slope.isFinite,
              duration.isFinite, duration > 0, alpha.isFinite, alpha > 0,
              eta.isFinite, eta >= 0 else { throw ValidatedScalarBarrierFailure.invalidCoefficients }
        try budget.chargeWork(workUnits)

        let r0 = try scalar(initialRadius), c = try scalar(slope)
        let a = try scalar(alpha), forcing = try scalar(eta)
        let end = try r0.adding(c.multiplied(by: scalar(duration)))
        let endBounds = try bounds(end)
        let initialGap = try c.adding(a.multiplied(by: r0)).subtracting(forcing)
        let endGap = try c.adding(a.multiplied(by: end)).subtracting(forcing)
        // Both expressions are affine; endpoint lower bounds cover the closed slab.
        guard endBounds.lower >= 0, try bounds(initialGap).lower >= 0,
              try bounds(endGap).lower >= 0 else {
            throw ValidatedScalarBarrierFailure.proposalNotCertified
        }
        guard !cancellation.isCancelled, !Task.isCancelled else { throw AnalysisError.cancelled }
        return Self(initialRadius: initialRadius, slope: slope, duration: duration,
            contractionLowerBound: alpha, forcingUpperBound: eta,
            endpointRadiusUpperBound: endBounds.upper)
    }

    private static func scalar(_ value: Double) throws -> CompensatedEnclosure {
        try CompensatedEnclosure(center: CompensatedValue(high: value))
    }

    private static func bounds(_ value: CompensatedEnclosure) throws -> (lower: Double, upper: Double) {
        let center = value.center.bounds
        let lower = value.radius == 0 ? center.lower : (center.lower - value.radius).nextDown
        let upper = value.radius == 0 ? center.upper : (center.upper + value.radius).nextUp
        guard lower.isFinite, upper.isFinite else { throw NumericalStateError.arithmeticOverflow }
        return (lower, upper)
    }
}

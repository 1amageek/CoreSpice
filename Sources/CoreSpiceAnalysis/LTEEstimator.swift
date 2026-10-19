import CoreSpiceDevices
import Foundation

/// Local Truncation Error (LTE) estimator for adaptive timestep control.
///
/// Estimates the LTE from successive solution vectors and proposes
/// an optimal next timestep based on the error and the integration
/// method order.
public struct LTEEstimator: Sendable {

    public enum EstimationError: Error, Sendable, Equatable {
        case insufficientHistory
        case invalidVectorDimensions
        case invalidTimeSteps
        case invalidTolerance
    }

    public init() {}

    /// Estimates the maximum normalized local truncation error across all variables.
    ///
    /// Each variable's raw LTE is divided by a tolerance that depends on the
    /// node voltage: `reltol * |x| + vntol`. Branch-current variables
    /// are excluded; `abstol` does not contribute to this estimator. The returned value is
    /// dimensionless: 1.0 means the worst variable is exactly at its tolerance
    /// boundary.
    ///
    /// - Parameters:
    ///   - current: Solution vector at the current time point.
    ///   - previous: Solution vector at the previous time point.
    ///   - twoPrevious: Solution vector two steps back (required for both methods).
    ///   - timeStep: The current timestep.
    ///   - previousTimeStep: The previous timestep (required for both methods).
    ///   - method: The integration method in use.
    ///   - branchCurrentIndices: Indices of excluded branch current variables.
    ///   - reltol: Relative tolerance (default: 1e-3).
    ///   - vntol: Voltage node tolerance (default: 1e-6 V).
    ///   - abstol: Absolute current tolerance (default: 1e-12 A).
    /// - Returns: The estimated maximum normalized LTE (dimensionless, 1.0 = at tolerance).
    public func estimate(
        current: [Double],
        previous: [Double],
        twoPrevious: [Double]?,
        timeStep: Double,
        previousTimeStep: Double?,
        method: IntegrationMethod,
        branchCurrentIndices: Set<Int> = [],
        reltol: Double = 1e-3,
        vntol: Double = 1e-6,
        abstol: Double = 1e-12,
        earlyExitThreshold: Double? = nil,
        threePrevious: [Double]? = nil,
        twoPreviousTimeStep: Double? = nil,
        variableAbsoluteTolerances: [Double]? = nil
    ) throws(EstimationError) -> Double {
        guard current.count == previous.count, let twoPrevious, twoPrevious.count == current.count else {
            if twoPrevious == nil { throw .insufficientHistory }
            throw .invalidVectorDimensions
        }
        guard let previousTimeStep else { throw .insufficientHistory }
        guard timeStep > 0, timeStep.isFinite, previousTimeStep > 0, previousTimeStep.isFinite else { throw .invalidTimeSteps }
        guard reltol >= 0, reltol.isFinite, vntol > 0, vntol.isFinite else { throw .invalidTolerance }
        if method == .trapezoidal {
            guard let threePrevious, let twoPreviousTimeStep else { throw .insufficientHistory }
            guard threePrevious.count == current.count else { throw .invalidVectorDimensions }
            guard twoPreviousTimeStep > 0, twoPreviousTimeStep.isFinite else { throw .invalidTimeSteps }
        }
        if let tolerances = variableAbsoluteTolerances {
            guard tolerances.count == current.count, tolerances.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw .invalidTolerance }
        }
        var maxLTE: Double = 0

        // Early exit threshold: if LTE exceeds this value, return immediately.
        // Using 1.2x the typical tolerance (1.0) provides a safety margin while
        // allowing early termination when the step will clearly be rejected.
        let exitThreshold = earlyExitThreshold ?? 1.2

        for i in 0..<current.count {
            // Skip branch current variables — standard SPICE practice.
            // Branch currents are auxiliary MNA variables constrained by
            // voltage sources; their rapid changes at waveform transitions
            // do not reflect integration error and would force unnecessarily
            // small timesteps.
            if branchCurrentIndices.contains(i) { continue }

            let lte: Double

            switch method {
            case .backwardEuler:
                do {
                    let tp = twoPrevious, prevDt = previousTimeStep
                    let d1Cur = (current[i] - previous[i]) / timeStep
                    let d1Prev = (previous[i] - tp[i]) / prevDt
                    let xpp = 2.0 * (d1Cur - d1Prev) / (timeStep + prevDt)
                    lte = abs(timeStep * timeStep * xpp / 2.0)
                }

            case .trapezoidal:
                guard let third = threePrevious, let olderDt = twoPreviousTimeStep else {
                    throw .insufficientHistory
                }
                let recentSlope = (current[i] - previous[i]) / timeStep
                let middleSlope = (previous[i] - twoPrevious[i]) / previousTimeStep
                let olderSlope = (twoPrevious[i] - third[i]) / olderDt
                let recentSecond = (recentSlope - middleSlope) / (timeStep + previousTimeStep)
                let olderSecond = (middleSlope - olderSlope) / (previousTimeStep + olderDt)
                let thirdDifference = (recentSecond - olderSecond) / (timeStep + previousTimeStep + olderDt)
                lte = abs(timeStep * timeStep * timeStep * thirdDifference / 2.0)
            }

            // Normalize by voltage node tolerance
            let tol = reltol * abs(current[i]) + (variableAbsoluteTolerances?[i] ?? vntol)
            let normalizedLTE = lte / tol
            guard normalizedLTE.isFinite else { return .infinity }
            maxLTE = max(maxLTE, normalizedLTE)

            // Early exit: if LTE already exceeds threshold, no need to check
            // remaining variables since the step will be rejected anyway.
            if maxLTE > exitThreshold {
                return maxLTE
            }
        }

        return maxLTE
    }

    /// Compares independent positive-time BE trials without using an inconsistent algebraic t=0 value.
    func estimateBootstrap(
        current: [Double], half: [Double], quarter: [Double],
        branchCurrentIndices: Set<Int>, reltol: Double, vntol: Double,
        variableAbsoluteTolerances: [Double]? = nil
    ) throws(EstimationError) -> Double {
        guard current.count == half.count, current.count == quarter.count else { throw .invalidVectorDimensions }
        guard reltol >= 0, reltol.isFinite, vntol > 0, vntol.isFinite else { throw .invalidTolerance }
        if let tolerances = variableAbsoluteTolerances {
            guard tolerances.count == current.count, tolerances.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw .invalidTolerance }
        }
        var maximum = 0.0
        for index in current.indices {
            if branchCurrentIndices.contains(index) { continue }
            let raw = (4.0 / 3.0) * abs(current[index] - 3 * half[index] + 2 * quarter[index])
            let normalized = raw / (reltol * abs(current[index]) + (variableAbsoluteTolerances?[index] ?? vntol))
            guard normalized.isFinite else { return .infinity }
            maximum = max(maximum, normalized)
        }
        return maximum
    }

    /// Embedded same-endpoint BE/TR estimate when distinct positive bootstrap times are unrepresentable.
    func estimateEmbedded(
        current: [Double], reference: [Double], branchCurrentIndices: Set<Int>,
        reltol: Double, vntol: Double, variableAbsoluteTolerances: [Double]? = nil
    ) throws(EstimationError) -> Double {
        guard current.count == reference.count else { throw .invalidVectorDimensions }
        guard reltol >= 0, reltol.isFinite, vntol > 0, vntol.isFinite else { throw .invalidTolerance }
        if let tolerances = variableAbsoluteTolerances {
            guard tolerances.count == current.count, tolerances.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw .invalidTolerance }
        }
        var maximum = 0.0
        for index in current.indices where !branchCurrentIndices.contains(index) {
            let normalized = abs(current[index] - reference[index])
                / (reltol * abs(current[index]) + (variableAbsoluteTolerances?[index] ?? vntol))
            guard normalized.isFinite else { return .infinity }
            maximum = max(maximum, normalized)
        }
        return maximum
    }

    /// Computes the optimal next timestep from the current LTE estimate.
    ///
    /// Uses the formula: `h_new = safety * h * (tol / lte)^(1/(p+1))`
    /// where `p` is the method order (1 for Backward Euler, 2 for Trapezoidal).
    ///
    /// - Parameters:
    ///   - currentStep: The timestep that produced the current LTE.
    ///   - lte: The estimated local truncation error (normalized, dimensionless).
    ///   - tolerance: The target LTE tolerance (dimensionless, typically 1.0).
    ///   - method: The integration method in use.
    /// - Returns: The proposed next timestep, clamped to at most `2 * currentStep`.
    public func optimalTimeStep(
        currentStep: Double,
        lte: Double,
        tolerance: Double,
        method: IntegrationMethod
    ) -> Double {
        guard lte > 0 else { return currentStep * 2.0 }
        let order: Double = method == .backwardEuler ? 1.0 : 2.0
        let ratio = tolerance / lte
        let factor = pow(ratio, 1.0 / (order + 1.0))
        let safetyFactor = 0.8
        return currentStep * min(safetyFactor * factor, 2.0)
    }
}

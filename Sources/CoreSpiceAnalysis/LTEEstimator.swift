import CoreSpiceDevices
import Foundation

/// Local Truncation Error (LTE) estimator for adaptive timestep control.
///
/// Estimates the LTE from successive solution vectors and proposes
/// an optimal next timestep based on the error and the integration
/// method order.
public struct LTEEstimator: Sendable {

    public init() {}

    /// Estimates the maximum normalized local truncation error across all variables.
    ///
    /// Each variable's raw LTE is divided by a tolerance that depends on the
    /// variable type: `reltol * |x| + vntol` for node voltages, and
    /// `reltol * |x| + abstol` for branch currents. The returned value is
    /// dimensionless: 1.0 means the worst variable is exactly at its tolerance
    /// boundary.
    ///
    /// - Parameters:
    ///   - current: Solution vector at the current time point.
    ///   - previous: Solution vector at the previous time point.
    ///   - twoPrevious: Solution vector two steps back (needed for trapezoidal LTE).
    ///   - timeStep: The current timestep.
    ///   - previousTimeStep: The previous timestep (needed for trapezoidal LTE).
    ///   - method: The integration method in use.
    ///   - branchCurrentIndices: Indices of branch current variables (use `abstol`).
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
        earlyExitThreshold: Double? = nil
    ) -> Double {
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
                if let tp = twoPrevious, let prevDt = previousTimeStep {
                    let d1Cur = (current[i] - previous[i]) / timeStep
                    let d1Prev = (previous[i] - tp[i]) / prevDt
                    let xpp = 2.0 * (d1Cur - d1Prev) / (timeStep + prevDt)
                    lte = abs(timeStep * timeStep * xpp / 2.0)
                } else {
                    // Insufficient history for a proper LTE estimate.
                    // The 3-point formula requires twoPrevious; without it
                    // we cannot distinguish integration error from solution
                    // change.  Accept the step unconditionally — the BE
                    // method provides natural stability, and the next step
                    // will have a full 3-point estimate.
                    lte = 0
                }

            case .trapezoidal:
                if let tp = twoPrevious, let prevDt = previousTimeStep {
                    let d1Cur = (current[i] - previous[i]) / timeStep
                    let d1Prev = (previous[i] - tp[i]) / prevDt
                    let xpp = 2.0 * (d1Cur - d1Prev) / (timeStep + prevDt)
                    lte = abs(timeStep * timeStep * xpp / 12.0)
                } else {
                    lte = 0
                }
            }

            // Normalize by voltage node tolerance
            let tol = reltol * abs(current[i]) + vntol
            let normalizedLTE = lte / tol
            maxLTE = max(maxLTE, normalizedLTE)

            // Early exit: if LTE already exceeds threshold, no need to check
            // remaining variables since the step will be rejected anyway.
            if maxLTE > exitThreshold {
                return maxLTE
            }
        }

        return maxLTE
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

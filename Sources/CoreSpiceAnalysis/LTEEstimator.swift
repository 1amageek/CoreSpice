import CoreSpiceDevices
import Foundation

/// Local Truncation Error (LTE) estimator for adaptive timestep control.
///
/// Estimates the LTE from successive solution vectors and proposes
/// an optimal next timestep based on the error and the integration
/// method order.
public struct LTEEstimator: Sendable {

    public init() {}

    /// Estimates the maximum local truncation error across all variables.
    ///
    /// - Parameters:
    ///   - current: Solution vector at the current time point.
    ///   - previous: Solution vector at the previous time point.
    ///   - twoPrevious: Solution vector two steps back (needed for trapezoidal LTE).
    ///   - timeStep: The current timestep.
    ///   - previousTimeStep: The previous timestep (needed for trapezoidal LTE).
    ///   - method: The integration method in use.
    /// - Returns: The estimated maximum LTE (infinity norm).
    public func estimate(
        current: [Double],
        previous: [Double],
        twoPrevious: [Double]?,
        timeStep: Double,
        previousTimeStep: Double?,
        method: IntegrationMethod
    ) -> Double {
        var maxLTE: Double = 0

        for i in 0..<current.count {
            let diff = current[i] - previous[i]
            let lte: Double

            switch method {
            case .backwardEuler:
                // Simplified LTE estimate for first-order method:
                // LTE ~ h/2 * |x''| ~ |dx|/2
                lte = abs(diff) * 0.5

            case .trapezoidal:
                if let tp = twoPrevious, let _ = previousTimeStep {
                    // Second-order estimate using three-point difference:
                    // d2 = x_n - 2*x_{n-1} + x_{n-2} ≈ h²·x''
                    // LTE for trapezoidal ≈ |d2| / 12
                    let d2 = current[i] - 2.0 * previous[i] + tp[i]
                    lte = abs(d2) / 12.0
                } else {
                    lte = abs(diff) * 0.5
                }
            }

            maxLTE = max(maxLTE, lte)
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
    ///   - lte: The estimated local truncation error.
    ///   - tolerance: The target LTE tolerance.
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

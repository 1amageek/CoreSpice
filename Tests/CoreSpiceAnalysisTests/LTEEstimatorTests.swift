import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceDevices

/// Unit tests for Local Truncation Error (LTE) estimation.
///
/// These tests verify the mathematical correctness of:
/// 1. LTE formula for Backward Euler and Trapezoidal methods
/// 2. Proper normalization using voltage tolerances
/// 3. Optimal timestep calculation with correct order exponents
@Suite("LTE Estimator Unit Tests")
struct LTEEstimatorTests {

    let estimator = LTEEstimator()

    // MARK: - Test 1: LTE Formula Accuracy (Backward Euler)

    /// Verifies the Backward Euler LTE formula using a known quadratic function.
    ///
    /// Mathematical basis:
    /// - For x(t) = t^2, the second derivative x'' = 2 (constant)
    /// - Three-point formula: xpp = 2 * (d1Cur - d1Prev) / (dt + dtPrev)
    /// - With x(0)=0, x(1)=1, x(2)=4: d1Prev = 1, d1Cur = 3, xpp = 2
    /// - BE LTE = |h^2 * xpp / 2| = |1^2 * 2 / 2| = 1.0
    @Test("LTE formula for Backward Euler with quadratic function x(t)=t^2")
    func lteFormulaBackwardEulerQuadratic() {
        // x(t) = t^2
        // t=0: x=0, t=1: x=1, t=2: x=4
        let twoPrevious = [0.0]  // x(0)
        let previous = [1.0]     // x(1)
        let current = [4.0]      // x(2)
        let dt = 1.0
        let dtPrev = 1.0

        // Expected calculation:
        // d1Cur = (4 - 1) / 1 = 3
        // d1Prev = (1 - 0) / 1 = 1
        // xpp = 2 * (3 - 1) / (1 + 1) = 2
        // LTE = |1^2 * 2 / 2| = 1.0
        // Normalized by (reltol * |x| + vntol) = (1e-3 * 4 + 1e-6) = 0.004001
        // Expected normalized LTE = 1.0 / 0.004001 ≈ 249.94

        let lte = estimator.estimate(
            current: current,
            previous: previous,
            twoPrevious: twoPrevious,
            timeStep: dt,
            previousTimeStep: dtPrev,
            method: .backwardEuler
        )

        let expectedRawLTE = 1.0  // h^2 * xpp / 2
        let tolerance = 1e-3 * 4.0 + 1e-6
        let expectedNormalized = expectedRawLTE / tolerance

        #expect(abs(lte - expectedNormalized) < 1e-6,
                "BE LTE should be \(expectedNormalized), got \(lte)")
    }

    /// Verifies BE LTE formula with cubic function for non-constant second derivative.
    ///
    /// Mathematical basis:
    /// - For x(t) = t^3, x''(t) = 6t
    /// - Discrete approximation uses the 3-point formula
    @Test("LTE formula for Backward Euler with cubic function x(t)=t^3")
    func lteFormulaBackwardEulerCubic() {
        // x(t) = t^3
        // t=0: x=0, t=1: x=1, t=2: x=8
        let twoPrevious = [0.0]
        let previous = [1.0]
        let current = [8.0]
        let dt = 1.0
        let dtPrev = 1.0

        // d1Cur = (8 - 1) / 1 = 7
        // d1Prev = (1 - 0) / 1 = 1
        // xpp = 2 * (7 - 1) / 2 = 6
        // LTE = |1^2 * 6 / 2| = 3.0

        let lte = estimator.estimate(
            current: current,
            previous: previous,
            twoPrevious: twoPrevious,
            timeStep: dt,
            previousTimeStep: dtPrev,
            method: .backwardEuler
        )

        let expectedRawLTE = 3.0
        let tolerance = 1e-3 * 8.0 + 1e-6
        let expectedNormalized = expectedRawLTE / tolerance

        #expect(abs(lte - expectedNormalized) < 1e-6,
                "BE LTE for cubic should be \(expectedNormalized), got \(lte)")
    }

    // MARK: - Test 2: LTE Formula Accuracy (Trapezoidal)

    /// Verifies the Trapezoidal LTE formula (coefficient 1/12 vs BE's 1/2).
    ///
    /// Mathematical basis:
    /// - TRAP LTE = |h^2 * x'' / 12|
    /// - For same quadratic x(t)=t^2, xpp = 2
    /// - TRAP LTE = |1^2 * 2 / 12| = 1/6 ≈ 0.1667
    @Test("LTE formula for Trapezoidal with quadratic function x(t)=t^2")
    func lteFormulaTrapezoidalQuadratic() {
        let twoPrevious = [0.0]
        let previous = [1.0]
        let current = [4.0]
        let dt = 1.0
        let dtPrev = 1.0

        let lte = estimator.estimate(
            current: current,
            previous: previous,
            twoPrevious: twoPrevious,
            timeStep: dt,
            previousTimeStep: dtPrev,
            method: .trapezoidal
        )

        let expectedRawLTE = 1.0 / 6.0  // h^2 * xpp / 12 = 1 * 2 / 12
        let tolerance = 1e-3 * 4.0 + 1e-6
        let expectedNormalized = expectedRawLTE / tolerance

        #expect(abs(lte - expectedNormalized) < 1e-6,
                "TRAP LTE should be \(expectedNormalized), got \(lte)")
    }

    /// Verifies TRAP LTE is 1/6 of BE LTE for identical inputs.
    ///
    /// Mathematical basis:
    /// - BE coefficient: 1/2
    /// - TRAP coefficient: 1/12
    /// - Ratio: (1/2) / (1/12) = 6
    @Test("Trapezoidal LTE is 1/6 of Backward Euler LTE")
    func trapLteIsOneSixthOfBE() {
        let twoPrevious = [0.0]
        let previous = [1.0]
        let current = [4.0]
        let dt = 1.0
        let dtPrev = 1.0

        let lteBE = estimator.estimate(
            current: current, previous: previous, twoPrevious: twoPrevious,
            timeStep: dt, previousTimeStep: dtPrev, method: .backwardEuler
        )

        let lteTRAP = estimator.estimate(
            current: current, previous: previous, twoPrevious: twoPrevious,
            timeStep: dt, previousTimeStep: dtPrev, method: .trapezoidal
        )

        #expect(abs(lteBE / lteTRAP - 6.0) < 1e-10,
                "BE/TRAP ratio should be 6, got \(lteBE / lteTRAP)")
    }

    // MARK: - Test 3: LTE with Unequal Timesteps

    /// Verifies correct handling of non-uniform timesteps.
    ///
    /// Mathematical basis:
    /// - xpp = 2 * (d1Cur - d1Prev) / (dt + dtPrev)
    /// - With dt=2, dtPrev=1: denominator = 3
    @Test("LTE calculation with unequal timesteps")
    func lteWithUnequalTimesteps() {
        // x(0) = 0, x(1) = 1, x(3) = 9 (quadratic x=t^2)
        let twoPrevious = [0.0]
        let previous = [1.0]
        let current = [9.0]
        let dt = 2.0      // from t=1 to t=3
        let dtPrev = 1.0  // from t=0 to t=1

        // d1Cur = (9 - 1) / 2 = 4
        // d1Prev = (1 - 0) / 1 = 1
        // xpp = 2 * (4 - 1) / (2 + 1) = 2 (correct for x=t^2)
        // BE LTE = |4 * 2 / 2| = 4

        let lte = estimator.estimate(
            current: current, previous: previous, twoPrevious: twoPrevious,
            timeStep: dt, previousTimeStep: dtPrev, method: .backwardEuler
        )

        let expectedRawLTE = 4.0  // dt^2 * xpp / 2 = 4 * 2 / 2
        let tolerance = 1e-3 * 9.0 + 1e-6
        let expectedNormalized = expectedRawLTE / tolerance

        #expect(abs(lte - expectedNormalized) < 1e-6,
                "LTE with unequal steps should be \(expectedNormalized), got \(lte)")
    }

    // MARK: - Test 4: LTE Normalization with Custom Tolerances

    /// Verifies normalization uses reltol * |x| + vntol correctly.
    @Test("LTE normalization with custom reltol and vntol")
    func lteNormalizationCustomTolerances() {
        let twoPrevious = [0.0]
        let previous = [1.0]
        let current = [4.0]
        let dt = 1.0
        let dtPrev = 1.0

        let reltol = 1e-4
        let vntol = 1e-9

        let lte = estimator.estimate(
            current: current, previous: previous, twoPrevious: twoPrevious,
            timeStep: dt, previousTimeStep: dtPrev, method: .backwardEuler,
            reltol: reltol, vntol: vntol
        )

        let rawLTE = 1.0  // h^2 * 2 / 2
        let tolerance = reltol * 4.0 + vntol  // 4e-4 + 1e-9
        let expectedNormalized = rawLTE / tolerance

        #expect(abs(lte - expectedNormalized) < 1e-3,
                "Custom tolerance normalization: expected \(expectedNormalized), got \(lte)")
    }

    /// Verifies that small x values are protected by absolute tolerance (vntol).
    @Test("LTE normalization protects small values with vntol")
    func lteNormalizationSmallValues() {
        // x values near zero: reltol * |x| is tiny, vntol dominates
        let twoPrevious = [0.0]
        let previous = [1e-9]
        let current = [4e-9]
        let dt = 1.0
        let dtPrev = 1.0

        let lte = estimator.estimate(
            current: current, previous: previous, twoPrevious: twoPrevious,
            timeStep: dt, previousTimeStep: dtPrev, method: .backwardEuler,
            reltol: 1e-3, vntol: 1e-6
        )

        // Raw LTE is very small, tolerance ≈ vntol = 1e-6
        // reltol * 4e-9 = 4e-12 << 1e-6
        let tolerance = 1e-3 * 4e-9 + 1e-6
        #expect(abs(tolerance - 1e-6) < 1e-9,
                "Tolerance should be dominated by vntol")

        // LTE should be finite (not blow up due to small denominator)
        #expect(lte.isFinite, "LTE must be finite for small values")
    }

    // MARK: - Test 5: Branch Currents are Skipped

    /// Verifies that branch current indices are excluded from LTE calculation.
    @Test("Branch current variables are excluded from LTE estimate")
    func branchCurrentsExcluded() {
        // Two variables: index 0 (voltage), index 1 (branch current)
        let twoPrevious = [0.0, 0.0]
        let previous = [1.0, 1e-3]
        let current = [4.0, 1e6]  // Large change in current (would dominate if included)
        let dt = 1.0
        let dtPrev = 1.0

        let lteWithCurrent = estimator.estimate(
            current: current, previous: previous, twoPrevious: twoPrevious,
            timeStep: dt, previousTimeStep: dtPrev, method: .backwardEuler,
            branchCurrentIndices: [1]  // Exclude index 1
        )

        let lteVoltageOnly = estimator.estimate(
            current: [4.0], previous: [1.0], twoPrevious: [0.0],
            timeStep: dt, previousTimeStep: dtPrev, method: .backwardEuler,
            branchCurrentIndices: []
        )

        #expect(abs(lteWithCurrent - lteVoltageOnly) < 1e-10,
                "LTE should ignore branch currents: \(lteWithCurrent) vs \(lteVoltageOnly)")
    }

    // MARK: - Test 6: Insufficient History Returns Zero

    /// Verifies that LTE returns 0 when twoPrevious or previousTimeStep is nil.
    @Test("LTE returns zero with insufficient history")
    func lteZeroWithInsufficientHistory() {
        let previous = [1.0]
        let current = [4.0]
        let dt = 1.0

        let lteNoTwoPrevious = estimator.estimate(
            current: current, previous: previous, twoPrevious: nil,
            timeStep: dt, previousTimeStep: 1.0, method: .backwardEuler
        )

        let lteNoPrevDt = estimator.estimate(
            current: current, previous: previous, twoPrevious: [0.0],
            timeStep: dt, previousTimeStep: nil, method: .backwardEuler
        )

        #expect(lteNoTwoPrevious == 0.0, "LTE should be 0 without twoPrevious")
        #expect(lteNoPrevDt == 0.0, "LTE should be 0 without previousTimeStep")
    }

    // MARK: - Test 7: Optimal Timestep (Backward Euler, p=1)

    /// Verifies optimal timestep formula for Backward Euler.
    ///
    /// Mathematical basis:
    /// - h_new = safety * h * (tol / lte)^(1/(p+1))
    /// - For BE: p=1, exponent = 1/2
    /// - safety = 0.8
    @Test("Optimal timestep for Backward Euler (order p=1)")
    func optimalTimestepBackwardEuler() {
        let currentStep = 1e-6
        let lte = 4.0  // LTE is 4x tolerance
        let tolerance = 1.0

        // Expected: 0.8 * 1e-6 * (1/4)^(1/2) = 0.8 * 1e-6 * 0.5 = 4e-7
        let expected = 0.8 * currentStep * pow(tolerance / lte, 1.0 / 2.0)

        let optimal = estimator.optimalTimeStep(
            currentStep: currentStep, lte: lte,
            tolerance: tolerance, method: .backwardEuler
        )

        #expect(abs(optimal - expected) < 1e-15,
                "BE optimal step should be \(expected), got \(optimal)")
    }

    // MARK: - Test 8: Optimal Timestep (Trapezoidal, p=2)

    /// Verifies optimal timestep formula for Trapezoidal.
    ///
    /// Mathematical basis:
    /// - For TRAP: p=2, exponent = 1/3
    @Test("Optimal timestep for Trapezoidal (order p=2)")
    func optimalTimestepTrapezoidal() {
        let currentStep = 1e-6
        let lte = 8.0  // LTE is 8x tolerance
        let tolerance = 1.0

        // Expected: 0.8 * 1e-6 * (1/8)^(1/3)
        let expected = 0.8 * currentStep * pow(tolerance / lte, 1.0 / 3.0)

        let optimal = estimator.optimalTimeStep(
            currentStep: currentStep, lte: lte,
            tolerance: tolerance, method: .trapezoidal
        )

        #expect(abs(optimal - expected) < 1e-15,
                "TRAP optimal step should be \(expected), got \(optimal)")
    }

    // MARK: - Test 9: Optimal Timestep Growth Limit

    /// Verifies timestep growth is capped at 2x.
    @Test("Optimal timestep capped at 2x current step")
    func optimalTimestepGrowthLimit() {
        let currentStep = 1e-6
        let lte = 1e-6  // Very small LTE would suggest huge increase
        let tolerance = 1.0

        let optimal = estimator.optimalTimeStep(
            currentStep: currentStep, lte: lte,
            tolerance: tolerance, method: .backwardEuler
        )

        // Even with tiny LTE, max growth is 2x
        #expect(optimal <= 2.0 * currentStep,
                "Optimal step \(optimal) should not exceed 2x = \(2.0 * currentStep)")
    }

    // MARK: - Test 10: Optimal Timestep with Zero LTE

    /// Verifies behavior when LTE is exactly zero (returns 2x step).
    @Test("Optimal timestep doubles when LTE is zero")
    func optimalTimestepZeroLTE() {
        let currentStep = 1e-6

        let optimal = estimator.optimalTimeStep(
            currentStep: currentStep, lte: 0.0,
            tolerance: 1.0, method: .backwardEuler
        )

        #expect(abs(optimal - 2.0 * currentStep) < 1e-15,
                "Zero LTE should yield 2x step: got \(optimal)")
    }

    // MARK: - Test 11: Multi-Variable Maximum Selection

    /// Verifies that maximum normalized LTE across variables is returned.
    @Test("Returns maximum normalized LTE across all variables")
    func maxNormalizedLTE() {
        // Three variables with different LTE contributions
        let twoPrevious = [0.0, 0.0, 0.0]
        let previous = [1.0, 1.0, 1.0]
        let current = [4.0, 2.0, 10.0]  // Variable 2 has largest change
        let dt = 1.0
        let dtPrev = 1.0

        let lte = estimator.estimate(
            current: current, previous: previous, twoPrevious: twoPrevious,
            timeStep: dt, previousTimeStep: dtPrev, method: .backwardEuler,
            earlyExitThreshold: .infinity  // Disable early exit to find actual maximum
        )

        // Variable 2: d1Cur = 9, d1Prev = 1, xpp = 8, raw LTE = 4
        // Normalized by (1e-3 * 10 + 1e-6) = 0.010001
        // Normalized LTE ≈ 4 / 0.010001 ≈ 400
        let expectedMax = 4.0 / (1e-3 * 10.0 + 1e-6)

        #expect(abs(lte - expectedMax) < 1.0,
                "Max LTE should be from variable 2: expected ~\(expectedMax), got \(lte)")
    }
}

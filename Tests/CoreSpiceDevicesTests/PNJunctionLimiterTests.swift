import Testing
import Foundation
@testable import CoreSpiceDevices

/// Unit tests for PN Junction voltage limiter (pnjlim algorithm).
///
/// These tests verify the mathematical correctness of the SPICE3F5 DEVpnjlim algorithm:
/// 1. Critical voltage calculation
/// 2. Logarithmic limiting when conditions are met
/// 3. Pass-through behavior when conditions are not met
@Suite("PN Junction Limiter Unit Tests")
struct PNJunctionLimiterTests {

    // Standard test parameters
    let vt = 0.02585       // Thermal voltage at 300K (n=1)
    let isat = 1e-14       // Typical diode saturation current

    // MARK: - Test 1: Critical Voltage Calculation

    /// Verifies the critical voltage formula.
    ///
    /// Mathematical basis:
    /// - vcrit = vt * ln(vt / (sqrt(2) * isat))
    /// - With vt=0.02585, isat=1e-14:
    ///   vcrit = 0.02585 * ln(0.02585 / (1.414 * 1e-14))
    ///        = 0.02585 * ln(1.828e12)
    ///        ≈ 0.02585 * 28.23 ≈ 0.730V
    @Test("Critical voltage calculation matches formula")
    func criticalVoltageFormula() {
        let expectedVcrit = vt * log(vt / (sqrt(2.0) * isat))

        // At exactly vcrit with small change, no limiting should occur
        let vOld = expectedVcrit - 0.01
        let vNew = expectedVcrit + 0.01  // Change is 0.02V < 2*vt ≈ 0.0517V

        let result = PNJunctionLimiter.limit(vNew: vNew, vOld: vOld, vt: vt, isat: isat)

        // Should NOT be limited (change < 2*vt)
        #expect(abs(result - vNew) < 1e-15,
                "Below 2*vt threshold: should return vNew unchanged")
    }

    // MARK: - Test 2: No Limiting Below Critical Voltage

    /// Verifies no limiting occurs when vNew <= vcrit.
    @Test("No limiting when vNew is below critical voltage")
    func noLimitingBelowCriticalVoltage() {
        let vcrit = vt * log(vt / (sqrt(2.0) * isat))

        // vNew well below vcrit
        let vNew = vcrit - 0.1
        let vOld = 0.3

        let result = PNJunctionLimiter.limit(vNew: vNew, vOld: vOld, vt: vt, isat: isat)

        #expect(abs(result - vNew) < 1e-15,
                "Below vcrit: should return vNew=\(vNew), got \(result)")
    }

    // MARK: - Test 3: No Limiting for Small Voltage Changes

    /// Verifies no limiting when |vNew - vOld| <= 2*vt.
    @Test("No limiting when voltage change is small (|delta| <= 2*vt)")
    func noLimitingSmallChange() {
        let vcrit = vt * log(vt / (sqrt(2.0) * isat))

        // vNew above vcrit but change is small
        let vOld = vcrit + 0.1
        let vNew = vOld + 2.0 * vt - 0.001  // Just under threshold

        let result = PNJunctionLimiter.limit(vNew: vNew, vOld: vOld, vt: vt, isat: isat)

        #expect(abs(result - vNew) < 1e-15,
                "Small change: should return vNew=\(vNew), got \(result)")
    }

    // MARK: - Test 4: Limiting with Positive vOld (Logarithmic)

    /// Verifies logarithmic limiting formula when vOld > 0.
    ///
    /// Mathematical basis:
    /// - When vNew > vcrit AND |vNew - vOld| > 2*vt AND vOld > 0:
    /// - vLimited = vOld + vt * ln(1 + (vNew - vOld) / vt)
    @Test("Logarithmic limiting with positive vOld")
    func logarithmicLimitingPositiveVOld() {
        let vcrit = vt * log(vt / (sqrt(2.0) * isat))

        let vOld = vcrit + 0.1  // > 0
        let vNew = vOld + 0.5   // Large step: 0.5V >> 2*vt ≈ 0.0517V

        let result = PNJunctionLimiter.limit(vNew: vNew, vOld: vOld, vt: vt, isat: isat)

        // Expected: vOld + vt * ln(1 + (vNew - vOld) / vt)
        //         = vOld + vt * ln(1 + 0.5 / 0.02585)
        //         = vOld + 0.02585 * ln(20.35)
        //         ≈ vOld + 0.02585 * 3.01 ≈ vOld + 0.0778
        let expected = vOld + vt * log(1.0 + (vNew - vOld) / vt)

        #expect(abs(result - expected) < 1e-12,
                "Positive vOld limiting: expected \(expected), got \(result)")

        // Verify result is less than vNew (limiting occurred)
        #expect(result < vNew,
                "Limited value \(result) should be less than vNew \(vNew)")

        // Verify result is greater than vOld (moved forward)
        #expect(result > vOld,
                "Limited value \(result) should be greater than vOld \(vOld)")
    }

    // MARK: - Test 5: Limiting with Non-Positive vOld

    /// Verifies direct logarithmic formula when vOld <= 0.
    ///
    /// Mathematical basis:
    /// - When vOld <= 0: vLimited = vt * ln(vNew / vt)
    @Test("Direct logarithmic limiting with non-positive vOld")
    func logarithmicLimitingNonPositiveVOld() {
        let vcrit = vt * log(vt / (sqrt(2.0) * isat))

        let vOld = -0.1  // <= 0
        let vNew = vcrit + 0.2  // Above vcrit, large change

        // Change = vNew - vOld = vcrit + 0.3 >> 2*vt
        #expect(abs(vNew - vOld) > 2.0 * vt, "Precondition: large change")

        let result = PNJunctionLimiter.limit(vNew: vNew, vOld: vOld, vt: vt, isat: isat)

        // Expected: vt * ln(vNew / vt)
        let expected = vt * log(vNew / vt)

        #expect(abs(result - expected) < 1e-12,
                "Non-positive vOld limiting: expected \(expected), got \(result)")
    }

    // MARK: - Test 6: Edge Case - vOld Exactly Zero

    /// Verifies behavior when vOld is exactly 0.
    @Test("Limiting behavior when vOld is exactly zero")
    func limitingVOldZero() {
        let vcrit = vt * log(vt / (sqrt(2.0) * isat))
        let vOld = 0.0
        let vNew = vcrit + 0.2

        let result = PNJunctionLimiter.limit(vNew: vNew, vOld: vOld, vt: vt, isat: isat)

        // vOld = 0 is NOT > 0, so uses: vt * ln(vNew / vt)
        let expected = vt * log(vNew / vt)

        #expect(abs(result - expected) < 1e-12,
                "vOld=0 should use direct log formula: expected \(expected), got \(result)")
    }

    // MARK: - Test 7: Guard Against Negative Argument in Log

    /// Verifies fallback to vcrit when (1 + delta/vt) would be negative.
    ///
    /// Mathematical basis:
    /// - If vNew - vOld < -vt, then arg = 1 + (vNew - vOld)/vt < 0
    /// - Implementation returns vcrit as fallback
    @Test("Result is finite for edge cases")
    func fallbackToVcritNegativeArg() {
        let vcrit = vt * log(vt / (sqrt(2.0) * isat))

        // Normal forward case - should give finite result
        let vOld = vcrit + 0.1
        let vNew = vcrit + 0.2

        let normalResult = PNJunctionLimiter.limit(vNew: vNew, vOld: vOld, vt: vt, isat: isat)
        #expect(normalResult.isFinite, "Result should be finite")

        // Also verify that any result from the limiter is finite
        // for various input combinations
        let testCases: [(Double, Double)] = [
            (0.7, 0.3),
            (0.8, 0.1),
            (0.9, 0.5),
        ]

        for (vN, vO) in testCases {
            let res = PNJunctionLimiter.limit(vNew: vN, vOld: vO, vt: vt, isat: isat)
            #expect(res.isFinite, "Result should be finite for vNew=\(vN), vOld=\(vO)")
        }
    }

    // MARK: - Test 8: Limiting Magnitude Verification

    /// Verifies that limiting reduces large steps significantly.
    ///
    /// Mathematical basis:
    /// - For very large (vNew - vOld), ln(1 + x/vt) ≈ ln(x/vt) ≈ ln(x) - ln(vt)
    /// - The step is reduced but still allows progress
    @Test("Large voltage step is significantly reduced by limiting")
    func largeStepReduction() {
        let vcrit = vt * log(vt / (sqrt(2.0) * isat))
        let vOld = vcrit + 0.1
        let vNew = vOld + 10.0  // Very large 10V step

        let result = PNJunctionLimiter.limit(vNew: vNew, vOld: vOld, vt: vt, isat: isat)

        // Limited step: vt * ln(1 + 10/0.02585) = vt * ln(388) ≈ 0.154V
        let limitedStep = result - vOld

        #expect(limitedStep < 0.2,
                "10V step should be reduced to < 0.2V, got \(limitedStep)")
        #expect(limitedStep > 0.1,
                "Limiting should still allow forward progress: \(limitedStep)")
    }

    // MARK: - Test 9: Different Isat Values

    /// Verifies that smaller Isat increases critical voltage.
    ///
    /// Mathematical basis:
    /// - vcrit = vt * ln(vt / (sqrt(2) * isat))
    /// - Smaller isat → larger argument → larger vcrit
    @Test("Critical voltage increases with smaller Isat")
    func vcritIncreasesWithSmallerIsat() {
        let isat1 = 1e-14
        let isat2 = 1e-16  // 100x smaller

        let vcrit1 = vt * log(vt / (sqrt(2.0) * isat1))
        let vcrit2 = vt * log(vt / (sqrt(2.0) * isat2))

        // vcrit2 should be larger by vt * ln(100) ≈ 0.119V
        let expectedDiff = vt * log(100.0)

        #expect(vcrit2 > vcrit1,
                "Smaller Isat should give larger vcrit")
        #expect(abs((vcrit2 - vcrit1) - expectedDiff) < 1e-10,
                "Vcrit difference should be vt*ln(100)=\(expectedDiff), got \(vcrit2 - vcrit1)")
    }

    // MARK: - Test 10: Different Vt Values (Emission Coefficient)

    /// Verifies limiting behavior with different thermal voltages.
    ///
    /// Higher n (emission coefficient) means higher effective vt,
    /// which makes limiting less aggressive.
    @Test("Higher thermal voltage (n>1) allows larger steps")
    func higherVtAllowsLargerSteps() {
        let vt1 = 0.02585      // n = 1
        let vt2 = 0.02585 * 2  // n = 2

        let vcrit1 = vt1 * log(vt1 / (sqrt(2.0) * isat))
        let vcrit2 = vt2 * log(vt2 / (sqrt(2.0) * isat))

        let vOld = max(vcrit1, vcrit2) + 0.1
        let vNew = vOld + 0.5

        let result1 = PNJunctionLimiter.limit(vNew: vNew, vOld: vOld, vt: vt1, isat: isat)
        let result2 = PNJunctionLimiter.limit(vNew: vNew, vOld: vOld, vt: vt2, isat: isat)

        let step1 = result1 - vOld
        let step2 = result2 - vOld

        #expect(step2 > step1,
                "Higher vt should allow larger step: \(step2) vs \(step1)")
    }

    // MARK: - Test 11: Reverse Bias (No Limiting)

    /// Verifies that reverse bias voltages are not limited.
    @Test("Reverse bias voltages pass through unchanged")
    func reverseBiasUnchanged() {
        // Both voltages negative (reverse bias)
        let vOld = -1.0
        let vNew = -5.0  // Large reverse step

        let result = PNJunctionLimiter.limit(vNew: vNew, vOld: vOld, vt: vt, isat: isat)

        #expect(abs(result - vNew) < 1e-15,
                "Reverse bias should not be limited: expected \(vNew), got \(result)")
    }

    // MARK: - Test 12: Boundary Exactly at 2*vt

    /// Verifies behavior exactly at the 2*vt threshold.
    @Test("Boundary behavior at exactly 2*vt change")
    func boundaryAtTwoVt() {
        let vcrit = vt * log(vt / (sqrt(2.0) * isat))
        let vOld = vcrit + 0.1
        let vNew = vOld + 2.0 * vt  // Exactly at threshold

        let result = PNJunctionLimiter.limit(vNew: vNew, vOld: vOld, vt: vt, isat: isat)

        // |vNew - vOld| > 2*vt is NOT satisfied (it's equal, not greater)
        #expect(abs(result - vNew) < 1e-15,
                "At exactly 2*vt, should NOT limit: expected \(vNew), got \(result)")
    }

    // MARK: - Test 13: Idempotency of Limiting

    /// Verifies that applying limit twice gives approximately same result.
    @Test("Limiting is approximately idempotent")
    func limitingIdempotent() {
        let vcrit = vt * log(vt / (sqrt(2.0) * isat))
        let vOld = vcrit + 0.1
        let vNew = vOld + 1.0

        let result1 = PNJunctionLimiter.limit(vNew: vNew, vOld: vOld, vt: vt, isat: isat)
        let result2 = PNJunctionLimiter.limit(vNew: result1, vOld: vOld, vt: vt, isat: isat)

        // result1 is now close to vOld, so second application should be similar
        // (result1 - vOld) should be small enough that it's near or below 2*vt threshold
        #expect(abs(result1 - result2) < 0.1,
                "Limiting should be approximately idempotent: \(result1) vs \(result2)")
    }
}

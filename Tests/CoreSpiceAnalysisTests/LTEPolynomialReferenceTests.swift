import Testing
@testable import CoreSpiceAnalysis

/// Independent local quadrature-defect references, not global solution-error bounds.
/// NIST DLMF 3.5.1 gives -h^3 * x'''(xi) / 12 for exact increment minus trapezoidal quadrature.
/// DLMF 3.3.34–36 gives the corresponding third divided difference on unequal nodes.
@Suite("LTE polynomial references")
struct LTEPolynomialReferenceTests {
    @Test(arguments: [2, 3])
    func polynomialDefectUsesThirdDerivative(_ degree: Int) throws {
        let values = degree == 2 ? [0.0, 1.0, 4.0, 9.0] : [0.0, 1.0, 8.0, 27.0]
        let actual = try estimate(values, steps: [1, 1, 1])
        let rawDefect = degree == 2 ? 0.0 : 0.5
        let expected = rawDefect / (0.001 * abs(values[3]) + 1)
        if degree == 2 {
            #expect(actual == 0)
        } else {
            expectRoundoffAgreement(actual, expected)
        }
    }

    @Test
    func halvingAllIntervalsReducesCubicDefectByEight() throws {
        let coarseValues = [0.0, 1.0, 8.0, 27.0]
        let fineValues = [0.0, 0.125, 1.0, 3.375]
        let coarse = try estimate(coarseValues, steps: [1, 1, 1])
        let fine = try estimate(fineValues, steps: [0.5, 0.5, 0.5])
        let coarseRaw = coarse * (0.001 * 27 + 1)
        let fineRaw = fine * (0.001 * 3.375 + 1)
        expectRoundoffAgreement(coarseRaw, 0.5)
        expectRoundoffAgreement(fineRaw, 0.0625)
        expectRoundoffAgreement(fineRaw / coarseRaw, 0.125)
    }

    @Test
    func unequalIntervalsUseTheirActualThreeSpans() throws {
        // t = 0, 1, 3, 6: first differences 1, 13, 63;
        // second differences 4, 10; third difference 1.
        let actual = try estimate([0, 1, 27, 216], steps: [1, 2, 3])
        let expected = 13.5 / (0.001 * 216 + 1)
        expectRoundoffAgreement(actual, expected)
    }

    @Test(arguments: [1.0, -1.0, 1e-6, -1e-6])
    func voltageScaleNormalizesAbsoluteDefect(_ amplitude: Double) throws {
        let voltageTolerance = 1e-9
        let values = [0, amplitude, 8 * amplitude, 27 * amplitude]
        let actual = try estimate(values, steps: [1, 1, 1], voltageTolerance: voltageTolerance)
        let expected = abs(amplitude) * 0.5 / (0.001 * abs(27 * amplitude) + voltageTolerance)
        expectRoundoffAgreement(actual, expected)
    }

    @Test(arguments: [1e-15, 1e-6])
    func auxiliaryBranchCurrentScaleDoesNotEnterVoltageEstimate(_ currentTolerance: Double) throws {
        let estimator = LTEEstimator()
        let actual = try estimator.estimate(
            current: [27e9, 27], previous: [8e9, 8], twoPrevious: [1e9, 1],
            timeStep: 1, previousTimeStep: 1, method: .trapezoidal,
            branchCurrentIndices: [0], reltol: 0.001, vntol: 1, abstol: currentTolerance,
            earlyExitThreshold: .infinity, threePrevious: [0, 0], twoPreviousTimeStep: 1
        )
        expectRoundoffAgreement(actual, 0.5 / (0.001 * 27 + 1))
        let branchOnly = try estimator.estimate(
            current: [27e9], previous: [8e9], twoPrevious: [1e9],
            timeStep: 1, previousTimeStep: 1, method: .trapezoidal,
            branchCurrentIndices: [0], reltol: 0.001, vntol: 1, abstol: currentTolerance,
            earlyExitThreshold: .infinity, threePrevious: [0], twoPreviousTimeStep: 1
        )
        #expect(branchOnly == 0)
    }

    private func estimate(
        _ values: [Double], steps: [Double], voltageTolerance: Double = 1
    ) throws -> Double {
        try LTEEstimator().estimate(
            current: [values[3]], previous: [values[2]], twoPrevious: [values[1]],
            timeStep: steps[2], previousTimeStep: steps[1], method: .trapezoidal,
            reltol: 0.001, vntol: voltageTolerance, abstol: 1e-15,
            earlyExitThreshold: .infinity, threePrevious: [values[0]], twoPreviousTimeStep: steps[0]
        )
    }

    private func expectRoundoffAgreement(_ actual: Double, _ expected: Double) {
        // This allowance covers floating-point evaluation, not an accuracy-policy relaxation.
        #expect(actual.isFinite)
        #expect(abs(actual - expected) <= 64 * Double.ulpOfOne * abs(expected))
    }
}

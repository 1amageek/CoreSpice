import CoreSpiceDevices
import Testing
@testable import CoreSpice

@Suite("Native matched-chart Lipschitz arithmetic", .timeLimit(.minutes(1)))
struct NativePrescribedVoltageLipschitzTests {
    private typealias Inverse = NativePrescribedVoltageEvolutionInverse

    @Test func directedNormProductEnclosesIndependentRationalBound() throws {
        // Scalar arithmetic cannot construct a source-bound chart or evolution result.
        let bound = try Inverse.lipschitzUpperBound(driftDerivativeNormUpperBound: 2,
            inverseNormUpperBound: 1.25, residualNormUpperBound: 0.25)
        #expect(bound >= 10.0 / 3.0 && bound < 10.0 / 3.0 + 0x1p-40)
        let nearUnit = try Inverse.lipschitzUpperBound(driftDerivativeNormUpperBound: 1,
            inverseNormUpperBound: 1, residualNormUpperBound: 1.0.nextDown)
        #expect(nearUnit >= 0x1p53 && nearUnit < 0x1p53 + 32)
    }

    @Test func exactZeroAndPositiveUnderflowHaveDistinctBounds() throws {
        #expect(try Inverse.lipschitzUpperBound(driftDerivativeNormUpperBound: 0,
            inverseNormUpperBound: .greatestFiniteMagnitude, residualNormUpperBound: 1.0.nextDown) == 0)
        #expect(try Inverse.lipschitzUpperBound(driftDerivativeNormUpperBound: .greatestFiniteMagnitude,
            inverseNormUpperBound: 0, residualNormUpperBound: 0.5) == 0)
        let tiny = try Inverse.lipschitzUpperBound(driftDerivativeNormUpperBound: .leastNonzeroMagnitude,
            inverseNormUpperBound: .leastNonzeroMagnitude, residualNormUpperBound: 0)
        #expect(tiny > 0 && tiny <= 2 * Double.leastNonzeroMagnitude)
        #expect(throws: NumericalStateError.arithmeticOverflow) {
            try Inverse.lipschitzUpperBound(driftDerivativeNormUpperBound: .greatestFiniteMagnitude,
                inverseNormUpperBound: 2, residualNormUpperBound: 0)
        }
        #expect(throws: NumericalStateError.arithmeticOverflow) {
            try Inverse.lipschitzUpperBound(driftDerivativeNormUpperBound: 1,
                inverseNormUpperBound: .greatestFiniteMagnitude, residualNormUpperBound: 1.0.nextDown)
        }
    }

    @Test func malformedNormsNeverBecomeSuccessfulZeroOrFiniteCertificates() throws {
        for (k, y, eta) in [(Double.nan, 1.0, 0.0), (1, Double.infinity, 0),
            (-1, 1, 0), (1, -1, 0), (1, 1, -0.5), (1, 1, 1), (0, 1, Double.nan)] {
            #expect(throws: NativePrescribedVoltageEvolutionFailure.invalidInput) {
                try Inverse.lipschitzUpperBound(driftDerivativeNormUpperBound: k,
                    inverseNormUpperBound: y, residualNormUpperBound: eta)
            }
        }
    }
}

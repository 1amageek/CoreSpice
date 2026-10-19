import Foundation
import Testing
@testable import CoreSpiceAnalysis

@Suite("QZ numerical primitives")
struct QZNumericalPrimitivesTests {
    // Standard roundoff accumulation bound for at most n elementary operations.
    private func gamma(_ n: Double) -> Double {
        let roundingUnit = Double.ulpOfOne / 2
        return n * roundingUnit / (1 - n * roundingUnit)
    }

    @Test("Givens preserves the norm and annihilates across exponent ranges")
    func givens() {
        let cases: [(Double, Double)] = [
            (0, 0), (-3, 0), (0, -4), (3, 4), (-3, 4), (3, -4),
            (3e-310, -4e-310), (3e300, 4e300),
            (Double.leastNonzeroMagnitude, Double.leastNonzeroMagnitude), (1e300, 1e-300)
        ]
        for (f, g) in cases {
            let rotation = QZNumericalPrimitives.givens(f, g)
            #expect(rotation.c.isFinite && rotation.s.isFinite && rotation.r.isFinite)
            #expect(rotation.c >= 0)
            #expect(abs(rotation.c * rotation.c + rotation.s * rotation.s - 1) <= gamma(12))
            let scale = max(abs(f), abs(g))
            if scale == 0 {
                #expect(rotation.r == 0)
                continue
            }
            let fs = f / scale
            let gs = g / scale
            #expect(abs(-rotation.s * fs + rotation.c * gs) <= gamma(12) * (abs(fs) + abs(gs)))
            let quantization = Double.leastNonzeroMagnitude / scale
            #expect(abs(rotation.c * fs + rotation.s * gs - rotation.r / scale)
                <= gamma(16) * (abs(fs) + abs(gs)) + quantization)
        }
        #expect(QZNumericalPrimitives.givens(-3, 4).r == -5)
        #expect(QZNumericalPrimitives.givens(0, -4).s == -1)
    }

    @Test("Householder annihilates both tails, including subnormal input")
    func householder() {
        let scales: [Double] = [1, 1e300, 1e-300, 1e-310]
        let signCases: [(Double, Double, Double)] = [(1, 2, -3), (-1, 2, 3), (0, -2, 3)]
        for scale in scales {
            for signs in signCases {
                let x = (signs.0 * scale, signs.1 * scale, signs.2 * scale)
                let reflection = QZNumericalPrimitives.householder(x.0, x.1, x.2)
                #expect(reflection.beta.isFinite)
                #expect(reflection.tau >= 1 && reflection.tau <= 2)
                let xs = (x.0 / scale, x.1 / scale, x.2 / scale)
                let dot = reflection.tau * (xs.0 + reflection.v2 * xs.1 + reflection.v3 * xs.2)
                let bound = gamma(40) * (abs(xs.0) + abs(xs.1) + abs(xs.2))
                    + Double.leastNonzeroMagnitude / scale
                #expect(abs(xs.0 - dot - reflection.beta / scale) <= bound)
                #expect(abs(xs.1 - reflection.v2 * dot) <= bound)
                #expect(abs(xs.2 - reflection.v3 * dot) <= bound)
                let vNormSquared = 1 + reflection.v2 * reflection.v2 + reflection.v3 * reflection.v3
                #expect(abs(reflection.tau * vNormSquared - 2) <= gamma(40))
            }
        }
        let identity = QZNumericalPrimitives.householder(-2, 0, 0)
        #expect(identity.beta == -2 && identity.tau == 0)
        #expect(identity.v2 == 0 && identity.v3 == 0)
        let smallest = QZNumericalPrimitives.householder(0, .leastNonzeroMagnitude, .leastNonzeroMagnitude)
        #expect(smallest.beta != 0 && smallest.beta.isFinite)
        #expect(smallest.tau == 1)
        #expect(abs(smallest.v2 * smallest.v2 + smallest.v3 * smallest.v3 - 1) <= gamma(12))
    }

    @Test("Triangular SVD reconstructs its signed diagonal with orthogonal rotations")
    func svd2x2() {
        let cases: [(Double, Double, Double)] = [
            (0, 0, 0), (-2, 0, 3), (3, 4, 2), (-3, 4, -2), (2, -4, 3),
            (0, -4, 0), (1, 1e-200, -1), (1e-300, 1e300, 1e-200),
            (3e300, -4e300, 2e300), (3e-310, 4e-310, -2e-310)
        ]
        for (f, g, h) in cases {
            let svd = QZNumericalPrimitives.svd2x2(f, g, h)
            #expect(svd.ssmin.isFinite && svd.ssmax.isFinite)
            #expect(abs(svd.ssmax) >= abs(svd.ssmin))
            #expect(abs(svd.csl * svd.csl + svd.snl * svd.snl - 1) <= gamma(32))
            #expect(abs(svd.csr * svd.csr + svd.snr * svd.snr - 1) <= gamma(32))
            let scale = max(abs(f), abs(g), abs(h))
            if scale == 0 { continue }
            let fs = f / scale
            let gs = g / scale
            let hs = h / scale
            let left11 = svd.csl * fs
            let left12 = svd.csl * gs + svd.snl * hs
            let left21 = -svd.snl * fs
            let left22 = -svd.snl * gs + svd.csl * hs
            let d11 = left11 * svd.csr + left12 * svd.snr
            let d12 = -left11 * svd.snr + left12 * svd.csr
            let d21 = left21 * svd.csr + left22 * svd.snr
            let d22 = -left21 * svd.snr + left22 * svd.csr
            let bound = gamma(64) * (abs(fs) + abs(gs) + abs(hs))
                + Double.leastNonzeroMagnitude / scale
            #expect(abs(d11 - svd.ssmax / scale) <= bound)
            #expect(abs(d22 - svd.ssmin / scale) <= bound)
            #expect(abs(d12) <= bound && abs(d21) <= bound)
        }
        let diagonal = QZNumericalPrimitives.svd2x2(-2, 0, 3)
        #expect(diagonal.ssmax == 3 && diagonal.ssmin == -2)
    }

    @Test("Two by two eigenvalues preserve real and complex roots at extreme common scales")
    func eigenvalues2x2() {
        let scales: [Double] = [1, 1e280, 1e-280]
        for scale in scales {
            let complex = QZNumericalPrimitives.eigenvalues2x2(
                a11: scale, a12: -2 * scale, a21: 2 * scale, a22: scale,
                b11: scale, b12: 0, b22: scale
            )
            #expect(complex.scale1 > 0 && complex.scale1.isFinite)
            #expect(complex.scale1 == complex.scale2 && complex.wr1 == complex.wr2)
            #expect(abs(complex.wr1 / complex.scale1 - 1) <= gamma(64))
            #expect(abs(complex.wi / complex.scale1 - 2) <= 2 * gamma(64))
            let real = QZNumericalPrimitives.eigenvalues2x2(
                a11: 2 * scale, a12: scale, a21: 0, a22: -3 * scale,
                b11: scale, b12: 0, b22: scale
            )
            #expect(real.wi == 0)
            #expect(abs(real.wr1 / real.scale1 + 3) <= 3 * gamma(64))
            #expect(abs(real.wr2 / real.scale2 - 2) <= 2 * gamma(64))
        }
    }
}

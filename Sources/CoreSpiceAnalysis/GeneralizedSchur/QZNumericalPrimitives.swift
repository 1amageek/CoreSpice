import Foundation

// Swift translations of Reference-LAPACK v3.12.1 DLARTG, DLARFG, DLAG2 and DLASV2.
// Copyright (c) 1992-2023 The University of Tennessee and The University
// of Tennessee Research Foundation. All rights reserved.
// Copyright (c) 2000-2023 The University of California Berkeley. All rights reserved.
// Copyright (c) 2006-2023 The University of Colorado Denver. All rights reserved.
// BSD redistribution conditions and disclaimer: THIRD_PARTY_NOTICES.txt.
enum QZNumericalPrimitives {
    static let safeMinimum = Double.leastNormalMagnitude
    static let ulp = Double.ulpOfOne

    static func givens(_ f: Double, _ g: Double) -> (c: Double, s: Double, r: Double) {
        let f1 = abs(f)
        let g1 = abs(g)
        if g == 0 { return (1, 0, f) }
        if f == 0 { return (0, copysign(1, g), g1) }
        let rootMinimum = safeMinimum.squareRoot()
        let safeMaximum = 1 / safeMinimum
        let rootMaximum = (safeMaximum / 2).squareRoot()
        if f1 > rootMinimum && f1 < rootMaximum && g1 > rootMinimum && g1 < rootMaximum {
            let d = (f * f + g * g).squareRoot()
            let r = copysign(d, f)
            return (f1 / d, g / r, r)
        }
        let scale = min(safeMaximum, max(safeMinimum, f1, g1))
        let fs = f / scale
        let gs = g / scale
        let d = (fs * fs + gs * gs).squareRoot()
        let r = copysign(d, f)
        return (abs(fs) / d, gs / r, r * scale)
    }

    static func householder(_ x1: Double, _ x2: Double, _ x3: Double)
        -> (beta: Double, tau: Double, v2: Double, v3: Double) {
        var alpha = x1
        var v2 = x2
        var v3 = x3
        var tailNorm = hypot(v2, v3)
        if tailNorm == 0 { return (alpha, 0, v2, v3) }
        var beta = -copysign(hypot(alpha, tailNorm), alpha)
        // DLAMCH('E') is half of the spacing at one under round-to-nearest.
        let minimum = safeMinimum / (ulp / 2)
        var rescalings = 0
        if abs(beta) < minimum {
            let inverseMinimum = 1 / minimum
            repeat {
                rescalings += 1
                v2 *= inverseMinimum
                v3 *= inverseMinimum
                beta *= inverseMinimum
                alpha *= inverseMinimum
            } while abs(beta) < minimum && rescalings < 20
            tailNorm = hypot(v2, v3)
            beta = -copysign(hypot(alpha, tailNorm), alpha)
        }
        let tau = (beta - alpha) / beta
        let reciprocal = 1 / (alpha - beta)
        v2 *= reciprocal
        v3 *= reciprocal
        for _ in 0..<rescalings { beta *= minimum }
        return (beta, tau, v2, v3)
    }

    static func eigenvalues2x2(
        a11 inputA11: Double, a12 inputA12: Double, a21 inputA21: Double, a22 inputA22: Double,
        b11 inputB11: Double, b12 inputB12: Double, b22 inputB22: Double,
        minimum: Double = safeMinimum
    ) -> (scale1: Double, scale2: Double, wr1: Double, wr2: Double, wi: Double) {
        let safeMinimum = minimum
        let rootMinimum = safeMinimum.squareRoot()
        let rootMaximum = 1 / rootMinimum
        let safeMaximum = 1 / safeMinimum
        let aNorm = max(abs(inputA11) + abs(inputA21), abs(inputA12) + abs(inputA22), safeMinimum)
        let aScale = 1 / aNorm
        let a11 = aScale * inputA11
        let a21 = aScale * inputA21
        let a12 = aScale * inputA12
        let a22 = aScale * inputA22
        var b11 = inputB11
        var b12 = inputB12
        var b22 = inputB22
        // Unlike conventional DLAG2, never perturb a nonzero B diagonal: doing so can
        // lose a representable huge finite root during the following QZ rotations.
        // Only exact-zero inputs may use a shift estimate; callers do not classify it.
        let bMinimum = rootMinimum * max(abs(b11), abs(b12), abs(b22), rootMinimum)
        if b11 == 0 { b11 = copysign(bMinimum, b11) }
        if b22 == 0 { b22 = copysign(bMinimum, b22) }
        let bNorm = max(abs(b11), abs(b12) + abs(b22), safeMinimum)
        let bSize = max(abs(b11), abs(b22))
        let bScale = 1 / bSize
        b11 *= bScale
        b12 *= bScale
        b22 *= bScale
        let inverseB11 = 1 / b11
        let inverseB22 = 1 / b22
        let s1 = a11 * inverseB11
        let s2 = a22 * inverseB22
        let shiftedA12: Double
        let ss: Double
        let abi22: Double
        let pp: Double
        let shift: Double
        if abs(s1) <= abs(s2) {
            shiftedA12 = a12 - s1 * b12
            let shiftedA22 = a22 - s1 * b22
            ss = a21 * (inverseB11 * inverseB22)
            abi22 = shiftedA22 * inverseB22 - ss * b12
            pp = 0.5 * abi22
            shift = s1
        } else {
            shiftedA12 = a12 - s2 * b12
            let shiftedA11 = a11 - s2 * b11
            ss = a21 * (inverseB11 * inverseB22)
            abi22 = -ss * b12
            pp = 0.5 * (shiftedA11 * inverseB11 + abi22)
            shift = s2
        }
        let qq = ss * shiftedA12
        let discriminant: Double
        let root: Double
        if abs(pp * rootMinimum) >= 1 {
            let scaledPP = rootMinimum * pp
            discriminant = scaledPP * scaledPP + qq * safeMinimum
            root = abs(discriminant).squareRoot() * rootMaximum
        } else if pp * pp + abs(qq) <= safeMinimum {
            let scaledPP = rootMaximum * pp
            discriminant = scaledPP * scaledPP + qq * safeMaximum
            root = abs(discriminant).squareRoot() * rootMinimum
        } else {
            discriminant = pp * pp + qq
            root = abs(discriminant).squareRoot()
        }
        var wr1: Double
        var wr2: Double
        var wi: Double
        if discriminant >= 0 || root == 0 {
            let sum = pp + copysign(root, pp)
            let difference = pp - copysign(root, pp)
            let largeRoot = shift + sum
            var smallRoot = shift + difference
            if 0.5 * abs(largeRoot) > max(abs(smallRoot), safeMinimum) {
                let determinant = (a11 * a22 - a12 * a21) * (inverseB11 * inverseB22)
                smallRoot = determinant / largeRoot
            }
            if pp > abi22 {
                wr1 = min(largeRoot, smallRoot)
                wr2 = max(largeRoot, smallRoot)
            } else {
                wr1 = max(largeRoot, smallRoot)
                wr2 = min(largeRoot, smallRoot)
            }
            wi = 0
        } else {
            wr1 = shift + pp
            wr2 = wr1
            wi = root
        }
        let c1 = bSize * (safeMinimum * max(1, aScale))
        let c2 = safeMinimum * max(1, bNorm)
        let c3 = bSize * safeMinimum
        let c4 = aScale <= 1 && bSize <= 1 ? min(1, (aScale / safeMinimum) * bSize) : 1
        let c5 = aScale <= 1 || bSize <= 1 ? min(1, aScale * bSize) : 1
        // DLAG2's prescribed overflow guard; not an eigenvalue tolerance.
        let fuzzyOne = 1 + 1e-5
        let absoluteW = abs(wr1) + abs(wi)
        var wSize = max(safeMinimum, c1, fuzzyOne * (absoluteW * c2 + c3), min(c4, 0.5 * max(absoluteW, c5)))
        var scale1: Double
        var scale2 = 0.0
        if wSize != 1 {
            let wScale = 1 / wSize
            if wSize > 1 {
                scale1 = (max(aScale, bSize) * wScale) * min(aScale, bSize)
            } else {
                scale1 = (min(aScale, bSize) * wScale) * max(aScale, bSize)
            }
            wr1 *= wScale
            if wi != 0 {
                wi *= wScale
                wr2 = wr1
                scale2 = scale1
            }
        } else {
            scale1 = aScale * bSize
            scale2 = scale1
        }
        if wi == 0 {
            wSize = max(safeMinimum, c1, fuzzyOne * (abs(wr2) * c2 + c3), min(c4, 0.5 * max(abs(wr2), c5)))
            if wSize != 1 {
                let wScale = 1 / wSize
                if wSize > 1 {
                    scale2 = (max(aScale, bSize) * wScale) * min(aScale, bSize)
                } else {
                    scale2 = (min(aScale, bSize) * wScale) * max(aScale, bSize)
                }
                wr2 *= wScale
            } else {
                scale2 = aScale * bSize
            }
        }
        return (scale1, scale2, wr1, wr2, wi)
    }

    static func svd2x2(_ f: Double, _ g: Double, _ h: Double)
        -> (ssmin: Double, ssmax: Double, snr: Double, csr: Double, snl: Double, csl: Double) {
        var ft = f
        var fa = abs(ft)
        var ht = h
        var ha = abs(h)
        var maximumPosition = 1
        let swapped = ha > fa
        if swapped {
            maximumPosition = 3
            swap(&ft, &ht)
            swap(&fa, &ha)
        }
        let gt = g
        let ga = abs(gt)
        var ssmin: Double = 0
        var ssmax: Double = 0
        var clt: Double = 1
        var crt: Double = 1
        var slt: Double = 0
        var srt: Double = 0
        if ga == 0 {
            ssmin = ha
            ssmax = fa
        } else {
            var normalCase = true
            if ga > fa {
                maximumPosition = 2
                if fa / ga < ulp / 2 {
                    normalCase = false
                    ssmax = ga
                    ssmin = ha > 1 ? fa / (ga / ha) : (fa / ga) * ha
                    clt = 1
                    slt = ht / gt
                    srt = 1
                    crt = ft / gt
                }
            }
            if normalCase {
                let d = fa - ha
                var l = d == fa ? 1 : d / fa
                let m = gt / ft
                var t = 2 - l
                let mm = m * m
                let tt = t * t
                let s = (tt + mm).squareRoot()
                let r = l == 0 ? abs(m) : (l * l + mm).squareRoot()
                let a = 0.5 * (s + r)
                ssmin = ha / a
                ssmax = fa * a
                if mm == 0 {
                    if l == 0 {
                        t = copysign(2, ft) * copysign(1, gt)
                    } else {
                        t = gt / copysign(d, ft) + m / t
                    }
                } else {
                    t = (m / (s + t) + m / (r + l)) * (1 + a)
                }
                l = (t * t + 4).squareRoot()
                crt = 2 / l
                srt = t / l
                clt = (crt + srt * m) / a
                slt = (ht / ft) * srt / a
            }
        }
        let csl = swapped ? srt : clt
        let snl = swapped ? crt : slt
        let csr = swapped ? slt : crt
        let snr = swapped ? clt : srt
        let sign: Double
        switch maximumPosition {
        case 1: sign = copysign(1, csr) * copysign(1, csl) * copysign(1, f)
        case 2: sign = copysign(1, snr) * copysign(1, csl) * copysign(1, g)
        default: sign = copysign(1, snr) * copysign(1, snl) * copysign(1, h)
        }
        ssmax = copysign(ssmax, sign)
        ssmin = copysign(ssmin, sign * copysign(1, f) * copysign(1, h))
        return (ssmin, ssmax, snr, csr, snl, csl)
    }
}

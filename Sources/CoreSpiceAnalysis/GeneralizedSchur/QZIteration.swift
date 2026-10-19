import CoreSpiceCompile
import Foundation

/// Real generalized Hessenberg/Schur reduction; reference indexing is one-based.
struct QZIteration {
    let n: Int
    let control: (any LinearSolverExecutionControlling)?
    var h: QZMatrix
    var t: QZMatrix
    var q: QZMatrix
    var z: QZMatrix
    var alphaReal: [Double]
    var alphaImag: [Double]
    var beta: [Double]
    var sweeps = 0
    var lower = 1
    var upper: Int
    var finiteSpectrumProvenByTriangularB = false
    var classificationFloor = 0.0
    private let safeMin = Double.leastNormalMagnitude
    private let ulp = Double.ulpOfOne

    init(n: Int, a: [Double], b: [Double], control: (any LinearSolverExecutionControlling)?) throws {
        self.n = n; self.control = control; self.upper = n
        h = QZMatrix(n: n, values: a); t = QZMatrix(n: n, values: b)
        var identity = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            if i % 32 == 0 { try control?.checkpoint(workUnits: min(32, n - i)) }
            identity[i * n + i] = 1
        }
        q = QZMatrix(n: n, values: identity); z = QZMatrix(n: n, values: identity)
        alphaReal = [Double](repeating: 0, count: n + 1)
        alphaImag = alphaReal; beta = alphaReal
    }

    mutating func reduce() throws {
        try isolate()
        finiteSpectrumProvenByTriangularB = try hasNonsingularTriangularB()
        guard upper > lower else { return }
        // Triangularize B without inverting it, applying identical left transforms to A.
        for column in lower..<upper {
            for row in stride(from: upper, through: column + 1, by: -1) {
                try control?.checkpoint(workUnits: 16)
                let rotation = QZNumericalPrimitives.givens(t[row - 1, column], t[row, column])
                t[row - 1, column] = rotation.r; t[row, column] = 0
                try t.rotateRows(row - 1, row, from: column + 1, through: n,
                                 c: rotation.c, s: rotation.s, control: control)
                try h.rotateRows(row - 1, row, from: lower, through: n,
                                 c: rotation.c, s: rotation.s, control: control)
                try q.rotateColumns(row - 1, row, from: 1, through: n,
                                    c: rotation.c, s: rotation.s, control: control)
            }
        }
        guard upper - lower > 1 else { return }
        // DGGHRD: alternating left/right Givens preserve triangular B.
        for column in lower...(upper - 2) {
            for row in stride(from: upper, through: column + 2, by: -1) {
                try control?.checkpoint(workUnits: 32)
                let left = QZNumericalPrimitives.givens(h[row - 1, column], h[row, column])
                h[row - 1, column] = left.r; h[row, column] = 0
                try h.rotateRows(row - 1, row, from: column + 1, through: n,
                                 c: left.c, s: left.s, control: control)
                try t.rotateRows(row - 1, row, from: row - 1, through: n,
                                 c: left.c, s: left.s, control: control)
                try q.rotateColumns(row - 1, row, from: 1, through: n,
                                    c: left.c, s: left.s, control: control)
                let right = QZNumericalPrimitives.givens(t[row, row], t[row, row - 1])
                t[row, row] = right.r; t[row, row - 1] = 0
                try h.rotateColumns(row, row - 1, from: 1, through: n,
                                    c: right.c, s: right.s, control: control)
                try t.rotateColumns(row, row - 1, from: 1, through: row - 1,
                                    c: right.c, s: right.s, control: control)
                try z.rotateColumns(row, row - 1, from: 1, through: n,
                                    c: right.c, s: right.s, control: control)
            }
        }
    }

    mutating func iterate() throws {
        let aNorm = try frobenius(h), bNorm = try frobenius(t)
        guard aNorm.isFinite, bNorm.isFinite else { throw GeneralizedSchurError.nonFiniteArithmetic }
        let aTolerance = max(safeMin, ulp * aNorm)
        classificationFloor = max(safeMin, ulp * bNorm)
        let aScale = 1 / max(safeMin, aNorm), bScale = 1 / max(safeMin, bNorm)
        let (maximumSweeps, overflow) = (upper - lower + 1).multipliedReportingOverflow(by: 30)
        guard !overflow else { throw GeneralizedSchurError.invalidDimension(n) }
        for index in 1...n where index < lower || index > upper {
            try control?.checkpoint(workUnits: 4)
            try standardize(index)
            alphaReal[index] = h[index, index]; alphaImag[index] = 0; beta[index] = t[index, index]
        }
        var last = upper, iteration = 0, exceptionalShift = 0.0
        while last >= lower {
            guard sweeps < maximumSweeps else {
                throw GeneralizedSchurError.nonConvergence(first: 0, last: last - 1, sweeps: sweeps)
            }
            sweeps += 1
            try control?.checkpoint(workUnits: 64)
            var first = lower
            var deflate = last == lower
            if !deflate && abs(h[last, last - 1]) <= max(safeMin, ulp * (abs(h[last, last]) + abs(h[last - 1, last - 1]))) {
                h[last, last - 1] = 0; deflate = true
            }
            if !deflate && t[last, last] == 0 {
                t[last, last] = 0
                try splitInfinite(last)
                deflate = true
            }
            if !deflate {
                // DHGEQZ labels 40/50/60: split at H subdiagonal or chase a zero in T.
                search: for j in stride(from: last - 1, through: lower, by: -1) {
                    try control?.checkpoint(workUnits: 48)
                    let zeroA: Bool
                    if j == lower { zeroA = true }
                    else if abs(h[j, j - 1]) <= max(safeMin, ulp * (abs(h[j, j]) + abs(h[j - 1, j - 1]))) {
                        h[j, j - 1] = 0; zeroA = true
                    } else { zeroA = false }
                    if t[j, j] == 0 {
                        t[j, j] = 0
                        var twoSmall = false
                        if !zeroA {
                            var x = abs(h[j, j - 1]), y = abs(h[j, j])
                            let maximum = max(x, y)
                            if maximum < 1 && maximum != 0 { x /= maximum; y /= maximum }
                            twoSmall = x * (aScale * abs(h[j + 1, j])) <= y * (aScale * aTolerance)
                        }
                        if zeroA || twoSmall {
                            for chase in j..<last {
                                try control?.checkpoint(workUnits: 24)
                                let rotation = QZNumericalPrimitives.givens(h[chase, chase], h[chase + 1, chase])
                                h[chase, chase] = rotation.r; h[chase + 1, chase] = 0
                                try h.rotateRows(chase, chase + 1, from: chase + 1, through: n,
                                                 c: rotation.c, s: rotation.s, control: control)
                                try t.rotateRows(chase, chase + 1, from: chase + 1, through: n,
                                                 c: rotation.c, s: rotation.s, control: control)
                                try q.rotateColumns(chase, chase + 1, from: 1, through: n,
                                                    c: rotation.c, s: rotation.s, control: control)
                                if twoSmall { h[chase, chase - 1] *= rotation.c }
                                twoSmall = false
                                if t[chase + 1, chase + 1] != 0 {
                                    if chase + 1 >= last { deflate = true }
                                    else { first = chase + 1 }
                                    break search
                                }
                                t[chase + 1, chase + 1] = 0
                            }
                            try splitInfinite(last); deflate = true; break search
                        } else {
                            for chase in j..<last {
                                try control?.checkpoint(workUnits: 32)
                                let left = QZNumericalPrimitives.givens(t[chase, chase + 1], t[chase + 1, chase + 1])
                                t[chase, chase + 1] = left.r; t[chase + 1, chase + 1] = 0
                                try t.rotateRows(chase, chase + 1, from: chase + 2, through: n,
                                                 c: left.c, s: left.s, control: control)
                                try h.rotateRows(chase, chase + 1, from: chase - 1, through: n,
                                                 c: left.c, s: left.s, control: control)
                                try q.rotateColumns(chase, chase + 1, from: 1, through: n,
                                                    c: left.c, s: left.s, control: control)
                                let right = QZNumericalPrimitives.givens(h[chase + 1, chase], h[chase + 1, chase - 1])
                                h[chase + 1, chase] = right.r; h[chase + 1, chase - 1] = 0
                                try h.rotateColumns(chase, chase - 1, from: 1, through: chase,
                                                    c: right.c, s: right.s, control: control)
                                try t.rotateColumns(chase, chase - 1, from: 1, through: chase - 1,
                                                    c: right.c, s: right.s, control: control)
                                try z.rotateColumns(chase, chase - 1, from: 1, through: n,
                                                    c: right.c, s: right.s, control: control)
                            }
                            try splitInfinite(last); deflate = true; break search
                        }
                    } else if zeroA { first = j; break search }
                }
            }
            if deflate {
                try standardize(last)
                alphaReal[last] = h[last, last]; alphaImag[last] = 0; beta[last] = t[last, last]
                last -= 1; iteration = 0; exceptionalShift = 0
                continue
            }
            iteration += 1
            var scale = 1.0, wr = 0.0, wi = 0.0
            if iteration % 10 == 0 {
                if (Double(maximumSweeps) * safeMin) * abs(h[last, last - 1]) < abs(t[last - 1, last - 1]) {
                    exceptionalShift = h[last, last - 1] / t[last - 1, last - 1]
                } else { exceptionalShift += 1 / (safeMin * Double(maximumSweeps)) }
                wr = exceptionalShift
            } else {
                let shifts = QZNumericalPrimitives.eigenvalues2x2(a11: h[last - 1, last - 1],
                    a12: h[last - 1, last], a21: h[last, last - 1], a22: h[last, last],
                    b11: t[last - 1, last - 1], b12: t[last - 1, last], b22: t[last, last], minimum: safeMin * 100)
                scale = shifts.scale1; wr = shifts.wr1; wi = shifts.wi
                if abs((wr / scale) * t[last, last] - h[last, last]) > abs((shifts.wr2 / shifts.scale2) * t[last, last] - h[last, last]) {
                    scale = shifts.scale2; wr = shifts.wr2
                }
            }
            guard scale.isFinite, wr.isFinite, wi.isFinite, scale > 0 else {
                throw GeneralizedSchurError.shiftFailure
            }
            if wi == 0 {
                try singleShift(first: first, last: last, scale: scale, wr: wr,
                                aScale: aScale, bScale: bScale, aTolerance: aTolerance)
            } else if first + 1 == last {
                if try complexBlock(first: first, last: last) {
                    last = first - 1; iteration = 0; exceptionalShift = 0
                }
            } else {
                try doubleShift(first: first, last: last, aScale: aScale, bScale: bScale)
            }
            try checkFinite(h)
            try checkFinite(t)
        }
    }

    /// Refuses an unresolved classification without changing or filtering its beta.
    func validateClassification(at index: Int) throws {
        if finiteSpectrumProvenByTriangularB {
            guard beta[index] != 0 else {
                throw GeneralizedSchurError.unresolvedEigenvalueClassification(index: index - 1)
            }
        } else if t[index, index] != 0 && abs(t[index, index]) <= classificationFloor {
            throw GeneralizedSchurError.unresolvedEigenvalueClassification(index: index - 1)
        }
    }

    private func frobenius(_ matrix: QZMatrix) throws -> Double {
        var norm = 0.0
        for column in lower...upper {
            for row in lower...upper {
                if (row - lower) % 32 == 0 {
                    try control?.checkpoint(workUnits: min(32, upper - row + 1) * 4)
                }
                norm = hypot(norm, matrix[row, column])
            }
        }
        return norm
    }

    private func checkFinite(_ matrix: QZMatrix) throws {
        for index in matrix.values.indices {
            if index % 32 == 0 { try control?.checkpoint(workUnits: min(32, matrix.values.count - index)) }
            guard matrix.values[index].isFinite else { throw GeneralizedSchurError.nonFiniteArithmetic }
        }
    }

    private mutating func splitInfinite(_ last: Int) throws {
        guard last > 1 else { return }
        let rotation = QZNumericalPrimitives.givens(h[last, last], h[last, last - 1])
        h[last, last] = rotation.r; h[last, last - 1] = 0
        try h.rotateColumns(last, last - 1, from: 1, through: last - 1,
                            c: rotation.c, s: rotation.s, control: control)
        try t.rotateColumns(last, last - 1, from: 1, through: last - 1,
                            c: rotation.c, s: rotation.s, control: control)
        try z.rotateColumns(last, last - 1, from: 1, through: n,
                            c: rotation.c, s: rotation.s, control: control)
    }

    private mutating func standardize(_ index: Int) throws {
        guard t[index, index] < 0 else { return }
        for row in 1...index {
            if (row - 1) % 32 == 0 { try control?.checkpoint(workUnits: min(32, index - row + 1) * 2) }
            h[row, index] = -h[row, index]; t[row, index] = -t[row, index]
        }
        for row in 1...n {
            if (row - 1) % 32 == 0 { try control?.checkpoint(workUnits: min(32, n - row + 1)) }
            z[row, index] = -z[row, index]
        }
    }

    private mutating func singleShift(first: Int, last: Int, scale inputScale: Double, wr inputWR: Double,
        aScale: Double, bScale: Double, aTolerance: Double) throws {
        var scale = inputScale, wr = inputWR
        let maximum = 1 / safeMin
        var factor = 1.0
        var bound = min(aScale, 1) * (0.5 * maximum)
        if scale > bound { factor = bound / scale }
        bound = min(bScale, 1) * (0.5 * maximum)
        if abs(wr) > bound { factor = min(factor, bound / abs(wr)) }
        scale *= factor; wr *= factor
        var start = first
        if last - 1 >= first + 1 {
            for j in stride(from: last - 1, through: first + 1, by: -1) {
                try control?.checkpoint(workUnits: 24)
                var x = abs(scale * h[j, j - 1]), y = abs(scale * h[j, j] - wr * t[j, j])
                let maximum = max(x, y)
                if maximum < 1 && maximum != 0 { x /= maximum; y /= maximum }
                if abs((aScale * h[j + 1, j]) * x) <= (aScale * aTolerance) * y {
                    start = j; break
                }
            }
        }
        var rotation = QZNumericalPrimitives.givens(scale * h[start, start] - wr * t[start, start],
                                                   scale * h[start + 1, start])
        for j in start..<last {
            try control?.checkpoint(workUnits: 32)
            if j > start {
                rotation = QZNumericalPrimitives.givens(h[j, j - 1], h[j + 1, j - 1])
                h[j, j - 1] = rotation.r; h[j + 1, j - 1] = 0
            }
            try h.rotateRows(j, j + 1, from: j, through: n,
                             c: rotation.c, s: rotation.s, control: control)
            try t.rotateRows(j, j + 1, from: j, through: n,
                             c: rotation.c, s: rotation.s, control: control)
            try q.rotateColumns(j, j + 1, from: 1, through: n,
                                c: rotation.c, s: rotation.s, control: control)
            rotation = QZNumericalPrimitives.givens(t[j + 1, j + 1], t[j + 1, j])
            t[j + 1, j + 1] = rotation.r; t[j + 1, j] = 0
            try h.rotateColumns(j + 1, j, from: 1, through: min(j + 2, last),
                                c: rotation.c, s: rotation.s, control: control)
            try t.rotateColumns(j + 1, j, from: 1, through: j,
                                c: rotation.c, s: rotation.s, control: control)
            try z.rotateColumns(j + 1, j, from: 1, through: n,
                                c: rotation.c, s: rotation.s, control: control)
        }
    }

    private mutating func complexBlock(first: Int, last: Int) throws -> Bool {
        try control?.checkpoint(workUnits: 200)
        // DHGEQZ label 200: diagonalize the triangular 2x2 B block by its SVD.
        let svd = QZNumericalPrimitives.svd2x2(t[first, first], t[first, last], t[last, last])
        var cr = svd.csr, sr = svd.snr, b11 = svd.ssmax, b22 = svd.ssmin
        if b11 < 0 { cr = -cr; sr = -sr; b11 = -b11; b22 = -b22 }
        try h.rotateRows(first, last, from: first, through: n,
                         c: svd.csl, s: svd.snl, control: control)
        try h.rotateColumns(first, last, from: 1, through: last,
                            c: cr, s: sr, control: control)
        try t.rotateRows(first, last, from: last + 1, through: n,
                         c: svd.csl, s: svd.snl, control: control)
        try t.rotateColumns(first, last, from: 1, through: first - 1,
                            c: cr, s: sr, control: control)
        try q.rotateColumns(first, last, from: 1, through: n,
                            c: svd.csl, s: svd.snl, control: control)
        try z.rotateColumns(first, last, from: 1, through: n,
                            c: cr, s: sr, control: control)
        t[first, first] = b11; t[first, last] = 0
        t[last, first] = 0; t[last, last] = b22
        try standardize(last)
        let roots = QZNumericalPrimitives.eigenvalues2x2(a11: h[first, first], a12: h[first, last],
            a21: h[last, first], a22: h[last, last], b11: t[first, first], b12: 0,
            b22: t[last, last], minimum: safeMin * 100)
        // Rounding during standardization can move the shifts to the real axis.
        if roots.wi == 0 { return false }
        guard roots.scale1 > 0, roots.scale2 > 0 else { throw GeneralizedSchurError.shiftFailure }
        // DLAG2 already returns homogeneous coordinates; their common scale is free.
        // This avoids forming overflowing complex quotients solely to rescale them again.
        alphaReal[first] = roots.wr1; alphaImag[first] = roots.wi; beta[first] = roots.scale1
        alphaReal[last] = roots.wr2; alphaImag[last] = -roots.wi; beta[last] = roots.scale2
        return true
    }

    private mutating func doubleShift(first: Int, last: Int, aScale: Double, bScale: Double) throws {
        try control?.checkpoint(workUnits: 160)
        // DHGEQZ's QZIT formula forms the starting vector from local triangular solves,
        // not an inverse of the full (possibly singular) original B.
        let ad11 = (aScale * h[last - 1, last - 1]) / (bScale * t[last - 1, last - 1])
        let ad21 = (aScale * h[last, last - 1]) / (bScale * t[last - 1, last - 1])
        let ad12 = (aScale * h[last - 1, last]) / (bScale * t[last, last])
        let ad22 = (aScale * h[last, last]) / (bScale * t[last, last])
        let u12 = t[last - 1, last] / t[last, last]
        let ad11L = (aScale * h[first, first]) / (bScale * t[first, first])
        let ad21L = (aScale * h[first + 1, first]) / (bScale * t[first, first])
        let ad12L = (aScale * h[first, first + 1]) / (bScale * t[first + 1, first + 1])
        let ad22L = (aScale * h[first + 1, first + 1]) / (bScale * t[first + 1, first + 1])
        let ad32L = (aScale * h[first + 2, first + 1]) / (bScale * t[first + 1, first + 1])
        let u12L = t[first, first + 1] / t[first + 1, first + 1]
        let v1 = (ad11 - ad11L) * (ad22 - ad11L) - ad12 * ad21 + ad21 * u12 * ad11L
            + (ad12L - ad11L * u12L) * ad21L
        let v2 = ((ad22L - ad11L) - ad21L * u12L - (ad11 - ad11L) - (ad22 - ad11L) + ad21 * u12) * ad21L
        let v3 = ad32L * ad21L
        guard v1.isFinite, v2.isFinite, v3.isFinite else { throw GeneralizedSchurError.shiftFailure }
        var reflector = QZNumericalPrimitives.householder(v1, v2, v3)
        for j in first...(last - 2) {
            try control?.checkpoint(workUnits: 160)
            if j > first {
                reflector = QZNumericalPrimitives.householder(h[j, j - 1], h[j + 1, j - 1], h[j + 2, j - 1])
                h[j, j - 1] = reflector.beta; h[j + 1, j - 1] = 0; h[j + 2, j - 1] = 0
            }
            try h.reflectRows(j, from: j, through: n, tau: reflector.tau,
                              v2: reflector.v2, v3: reflector.v3, control: control)
            try t.reflectRows(j, from: j, through: n, tau: reflector.tau,
                              v2: reflector.v2, v3: reflector.v3, control: control)
            try q.reflectColumns(j, from: 1, through: n, tau: reflector.tau,
                                 v2: reflector.v2, v3: reflector.v3, control: control)

            // DHGEQZ label 250: pivoted local 2x2 elimination constructs a right reflector.
            var pivot = false, scale = 1.0, u1: Double, u2: Double
            let top = max(abs(t[j + 1, j + 1]), abs(t[j + 1, j + 2]))
            let bottom = max(abs(t[j + 2, j + 1]), abs(t[j + 2, j + 2]))
            if max(top, bottom) < safeMin {
                scale = 0; u1 = 1; u2 = 0
            } else {
                var w11: Double, w21: Double, w12: Double, w22: Double
                if top >= bottom {
                    w11 = t[j + 1, j + 1]; w21 = t[j + 2, j + 1]
                    w12 = t[j + 1, j + 2]; w22 = t[j + 2, j + 2]
                    u1 = t[j + 1, j]; u2 = t[j + 2, j]
                } else {
                    w21 = t[j + 1, j + 1]; w11 = t[j + 2, j + 1]
                    w22 = t[j + 1, j + 2]; w12 = t[j + 2, j + 2]
                    u2 = t[j + 1, j]; u1 = t[j + 2, j]
                }
                if abs(w12) > abs(w11) { pivot = true; swap(&w11, &w12); swap(&w21, &w22) }
                let multiplier = w21 / w11
                u2 -= multiplier * u1; w22 -= multiplier * w12
                if abs(w22) < safeMin {
                    scale = 0; u2 = 1; u1 = -w12 / w11
                } else {
                    if abs(w22) < abs(u2) { scale = abs(w22 / u2) }
                    if abs(w11) < abs(u1) { scale = min(scale, abs(w11 / u1)) }
                    u2 = (scale * u2) / w22
                    u1 = (scale * u1 - w12 * u2) / w11
                }
            }
            if pivot { swap(&u1, &u2) }
            let norm = hypot(scale, hypot(u1, u2))
            let tau = 1 + scale / norm
            let factor = -1 / (scale + norm)
            let rightV2 = factor * u1, rightV3 = factor * u2
            guard tau.isFinite, rightV2.isFinite, rightV3.isFinite else {
                throw GeneralizedSchurError.nonFiniteArithmetic
            }
            try h.reflectColumns(j, from: 1, through: min(j + 3, last), tau: tau,
                                 v2: rightV2, v3: rightV3, control: control)
            try t.reflectColumns(j, from: 1, through: j + 2, tau: tau,
                                 v2: rightV2, v3: rightV3, control: control)
            try z.reflectColumns(j, from: 1, through: n, tau: tau,
                                 v2: rightV2, v3: rightV3, control: control)
            t[j + 1, j] = 0; t[j + 2, j] = 0
        }
        let j = last - 1
        let left = QZNumericalPrimitives.givens(h[j, j - 1], h[j + 1, j - 1])
        h[j, j - 1] = left.r; h[j + 1, j - 1] = 0
        try h.rotateRows(j, j + 1, from: j, through: n, c: left.c, s: left.s, control: control)
        try t.rotateRows(j, j + 1, from: j, through: n, c: left.c, s: left.s, control: control)
        try q.rotateColumns(j, j + 1, from: 1, through: n, c: left.c, s: left.s, control: control)
        let right = QZNumericalPrimitives.givens(t[j + 1, j + 1], t[j + 1, j])
        t[j + 1, j + 1] = right.r; t[j + 1, j] = 0
        try h.rotateColumns(j + 1, j, from: 1, through: last, c: right.c, s: right.s, control: control)
        try t.rotateColumns(j + 1, j, from: 1, through: last - 1, c: right.c, s: right.s, control: control)
        try z.rotateColumns(j + 1, j, from: 1, through: n, c: right.c, s: right.s, control: control)
    }
}

import Synchronization
import Testing
@testable import CoreSpiceAnalysis
import CoreSpiceCompile

@Suite("Generalized Schur behavioral qualification")
struct GeneralizedSchurTests {
    @Test("Dense dyadic equivalence preserves real, zero and conjugate eigenvalues")
    func denseMixedSpectrum() throws {
        let pair = mixedPair()
        let result = try checkedDecomposition(pair.a, pair.b, dimension: 4)
        #expect(result.eigenvalues.count == 4)
        #expect(result.infiniteEigenvalueCount == 0)
        expectSpectrum(try result.finiteEigenvalues(), expected: mixedSpectrum)
    }

    @Test("Moderate dense pencils preserve repeated and clustered complex blocks", arguments: [3, 8, 17, 32])
    func moderateDenseFamilies(_ dimension: Int) throws {
        let pair = moderatePair(dimension: dimension, singular: false)
        let result = try checkedDecomposition(pair.a, pair.b, dimension: dimension)
        #expect(result.infiniteEigenvalueCount == 0)
        expectSpectrum(try result.finiteEigenvalues(), expected: pair.expected)
    }

    @Test("Exact isolated singularity resolves while dense rounding-scale classification is refused", arguments: [3, 8, 17, 32])
    func moderateDenseSingular(_ dimension: Int) throws {
        let pair = moderatePair(dimension: dimension, singular: true)
        if dimension == 3 {
            let result = try checkedDecomposition(pair.a, pair.b, dimension: dimension)
            #expect(result.infiniteEigenvalueCount == 1)
            expectSpectrum(try result.finiteEigenvalues(), expected: pair.expected)
        } else {
            do {
                _ = try GeneralizedSchur.decompose(matrixA: pair.a, matrixB: pair.b, dimension: dimension)
                Issue.record("Dense unresolved classification must not publish a partial or guessed spectrum")
            } catch GeneralizedSchurError.unresolvedEigenvalueClassification(let index) {
                #expect(index >= 0 && index < dimension)
            }
        }
    }

    @Test("Nilpotent triangular B preserves complete infinite multiplicity", arguments: [3, 8, 17, 32])
    func moderateNilpotentFamilies(_ dimension: Int) throws {
        var b = Array(repeating: 0.0, count: dimension * dimension)
        for column in 1..<dimension { b[column - 1 + column * dimension] = 1 }
        let result = try checkedDecomposition(identity(dimension), b, dimension: dimension)
        #expect(result.infiniteEigenvalueCount == dimension)
        #expect(try result.finiteEigenvalues().isEmpty)
        for value in result.eigenvalues {
            #expect(value.beta == 0)
            #expect(value.alphaReal != 0 || value.alphaImag != 0)
        }
    }

    @Test("Common and independent binary scales preserve original homogeneous coordinates")
    func binaryScaling() throws {
        let pair = mixedPair()
        for (aExponent, bExponent) in [(900, 900), (-900, -900), (500, -400), (-400, 500)] {
            let a = pair.a.map { scaled($0, by: aExponent) }
            let b = pair.b.map { scaled($0, by: bExponent) }
            let result = try checkedDecomposition(a, b, dimension: 4)
            #expect(result.eigenvalues.count == 4)
            #expect(result.infiniteEigenvalueCount == 0)
            let expected = mixedSpectrum.map {
                ComplexPair(real: scaled($0.real, by: aExponent - bExponent),
                            imag: scaled($0.imag, by: aExponent - bExponent))
            }
            expectSpectrum(try result.finiteEigenvalues(), expected: expected)
        }
    }

    @Test("A singular nilpotent B has two infinite eigenvalues")
    func nilpotentInfiniteMultiplicity() throws {
        let result = try checkedDecomposition([1, 0, 0, 1], [0, 0, 1, 0], dimension: 2)
        #expect(result.eigenvalues.count == 2)
        #expect(result.infiniteEigenvalueCount == 2)
        #expect(try result.finiteEigenvalues().isEmpty)
        for value in result.eigenvalues {
            #expect(value.beta == 0)
            #expect(value.alphaReal != 0 || value.alphaImag != 0)
        }
    }

    @Test("Dense singular classification either resolves its exact Schur zero or refuses ambiguity")
    func mixedFiniteAndInfinite() throws {
        let a = fromRows([[2, 0, 0, 0], [0, 0, -3, 0], [0, 3, 0, 0], [0, 0, 0, 5]])
        let b = fromRows([[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 0]])
        let pair = transform(a, b, dimension: 4)
        do {
            let result = try checkedDecomposition(pair.a, pair.b, dimension: 4)
            #expect(result.eigenvalues.count == 4)
            #expect(result.infiniteEigenvalueCount == 1)
            expectSpectrum(try result.finiteEigenvalues(), expected: [
                ComplexPair(real: 2), ComplexPair(imag: -3), ComplexPair(imag: 3)
            ])
        } catch GeneralizedSchurError.unresolvedEigenvalueClassification(let index) {
            #expect(index >= 0 && index < 4)
        }
    }

    @Test("A defective repeated pencil is qualified by backward error and multiplicity")
    func defectiveMultiplicity() throws {
        let a = fromRows([[1, 1, 0, 0], [0, 1, 1, 0], [0, 0, 1, 1], [0, 0, 0, 1]])
        let pair = transform(a, identity(4), dimension: 4)
        let result = try checkedDecomposition(pair.a, pair.b, dimension: 4)
        let finite = try result.finiteEigenvalues()
        #expect(finite.count == 4)
        #expect(result.infiniteEigenvalueCount == 0)
        // Individual roots of a defective pencil need not have small forward error.
        #expect(abs(finite.reduce(0.0) { $0 + $1.real } - 4) < 1e-10)
        #expect(abs(finite.reduce(0.0) { $0 + $1.imag }) < 1e-10)
    }

    @Test("A tiny nonzero beta is finite and a subnormal common pair remains one")
    func tinyHomogeneousComponents() throws {
        let tiny = try checkedDecomposition([1], [1e-300], dimension: 1)
        #expect(tiny.infiniteEigenvalueCount == 0)
        let tinyValue = try #require(tiny.eigenvalues.first)
        #expect(tinyValue.beta != 0)
        expectSpectrum(try tiny.finiteEigenvalues(), expected: [ComplexPair(real: 1e300)])

        let subnormal = Double.leastNonzeroMagnitude
        let common = try checkedDecomposition([subnormal], [subnormal], dimension: 1)
        #expect(common.infiniteEigenvalueCount == 0)
        expectSpectrum(try common.finiteEigenvalues(), expected: [.one])
    }

    @Test("A tiny beta beside a unit beta remains finite")
    func mixedScaleTinyBeta() throws {
        let beta = scaled(1, by: -1000)
        let result = try checkedDecomposition([1, 0, 0, 2], [beta, 0, 0, 1], dimension: 2)
        #expect(result.infiniteEigenvalueCount == 0)
        let finite = try result.finiteEigenvalues()
        try #require(finite.count == 2)
        let sorted = finite.sorted { $0.real < $1.real }
        #expect(abs(sorted[0].real - 2) < 1e-12)
        #expect(abs(sorted[1].real / scaled(1, by: 1000) - 1) < 1e-12)
        #expect(sorted[0].imag == 0)
        #expect(sorted[1].imag == 0)
        #expect(result.eigenvalues.allSatisfy { $0.beta != 0 })
    }

    @Test("Coupled tiny beta retains both representable finite roots")
    func coupledTinyBeta() throws {
        let epsilon = scaled(1, by: -1000)
        let result = try checkedDecomposition([1, 1, 1, 2], [1, 0, 0, epsilon], dimension: 2)
        #expect(result.infiniteEigenvalueCount == 0)
        #expect(result.eigenvalues.count == 2)
        for value in result.eigenvalues { #expect(value.beta != 0) }
        let finite = try result.finiteEigenvalues().sorted { $0.real < $1.real }
        try #require(finite.count == 2)
        // Each root has its own scale: the huge root cannot hide an inaccurate small root.
        #expect(abs(finite[0].real - 0.5) <= 32 * Double.ulpOfOne)
        #expect(abs(finite[1].real / (2 / epsilon) - 1) <= 32 * Double.ulpOfOne)
        #expect(finite[0].imag == 0 && finite[1].imag == 0)
    }

    @Test("Unresolved classification releases its complete temporary workspace")
    func unresolvedClassificationReleasesStorage() throws {
        let pair = moderatePair(dimension: 8, singular: true)
        let control = SchurTestControl()
        do {
            _ = try GeneralizedSchur.decompose(matrixA: pair.a, matrixB: pair.b, dimension: 8, control: control)
            Issue.record("Expected typed unresolved classification")
        } catch GeneralizedSchurError.unresolvedEigenvalueClassification(let index) {
            #expect(index >= 0 && index < 8)
        }
        #expect(control.snapshot.totalWork > 0)
        #expect(control.snapshot.reservations > 0)
        expectReleased(control)
    }

    @Test("An unrepresentable finite quotient fails rather than becoming infinity")
    func finiteProjectionOverflow() throws {
        let result = try checkedDecomposition([1], [.leastNonzeroMagnitude], dimension: 1)
        #expect(result.infiniteEigenvalueCount == 0)
        let value = try #require(result.eigenvalues.first)
        #expect(value.beta != 0)
        #expect(throws: (any Error).self) { _ = try result.finiteEigenvalues() }
    }

    @Test("Indeterminate, malformed and nonfinite pencils fail explicitly")
    func rejectedPencils() {
        for (a, b, n) in [
            ([0.0], [0.0], 1),
            ([1.0], [1.0, 0, 0, 1], 2),
            ([1.0], [1.0], -1),
            ([1.0], [1.0], Int.max),
            ([Double.nan], [1.0], 1),
            ([1.0], [Double.infinity], 1),
            ([-Double.infinity], [1.0], 1)
        ] {
            #expect(throws: (any Error).self) {
                _ = try GeneralizedSchur.decompose(matrixA: a, matrixB: b, dimension: n)
            }
        }
    }

    @Test("Later work refusal and callback cancellation release every workspace lease")
    func workAndCancellationDuringExecution() throws {
        let pair = mixedPair()
        let baseline = SchurTestControl()
        try runControlled(pair, control: baseline)
        let successful = baseline.snapshot
        #expect(successful.positiveCheckpoints >= 3)
        #expect(successful.totalWork > 0)
        expectReleased(baseline)

        for failure in [SchurTestControl.Stop.work, .cancelled] {
            let control = SchurTestControl(stop: failure, stopAtPositiveCheckpoint: 3)
            #expect(throws: failure) { try runControlled(pair, control: control) }
            let state = control.snapshot
            #expect(state.positiveCheckpoints == 3)
            #expect(state.admittedPositiveCheckpoints == 2)
            #expect(state.reservations > 0)
            expectReleased(control)
        }
    }

    @Test("Capacity refusal occurs before storage is retained and success refunds its lease")
    func capacityAndSuccessfulRelease() throws {
        let pair = mixedPair()
        let refused = SchurTestControl(capacity: 0)
        #expect(throws: SchurTestControl.Stop.capacity) { try runControlled(pair, control: refused) }
        #expect(refused.snapshot.reservationAttempts > 0)
        expectReleased(refused)

        let successful = SchurTestControl()
        try runControlled(pair, control: successful)
        #expect(successful.snapshot.reservations > 0)
        #expect(successful.snapshot.peakBytes > 0)
        expectReleased(successful)
    }

    private var mixedSpectrum: [ComplexPair] {
        [ComplexPair(), ComplexPair(real: 2, imag: -3),
         ComplexPair(real: 2, imag: 3), ComplexPair(real: -4)]
    }

    private func mixedPair() -> (a: [Double], b: [Double]) {
        let a = fromRows([[0, 0, 0, 0], [0, 2, -3, 0], [0, 3, 2, 0], [0, 0, 0, -4]])
        return transform(a, identity(4), dimension: 4)
    }

    private func moderatePair(dimension n: Int, singular: Bool)
        -> (a: [Double], b: [Double], expected: [ComplexPair]) {
        var s = Array(repeating: 0.0, count: n * n)
        var t = Array(repeating: 0.0, count: n * n)
        var expected: [ComplexPair] = []
        let scalarCount = n.isMultiple(of: 2) ? 2 : 1
        for index in 0..<scalarCount {
            let beta = singular && index == 0 ? 0.0 : (index == 0 ? 0.5 : 2.0)
            s[index + index * n] = index == 0 ? -1 : 0
            t[index + index * n] = beta
            if beta != 0 { expected.append(ComplexPair(real: s[index + index * n] / beta)) }
        }
        var block = 0
        for index in stride(from: scalarCount, to: n, by: 2) {
            let beta = scaled(1, by: block % 3 - 1)
            let real = 2.0 + (block % 3 == 1 ? 1.0 / 1024 : 0)
            let imaginary = 3.0 + (block % 3 == 2 ? 1.0 / 1024 : 0)
            s[index + index * n] = real * beta
            s[index + 1 + (index + 1) * n] = real * beta
            s[index + 1 + index * n] = imaginary * beta
            s[index + (index + 1) * n] = -imaginary * beta
            t[index + index * n] = beta
            t[index + 1 + (index + 1) * n] = beta
            expected.append(ComplexPair(real: real, imag: -imaginary))
            expected.append(ComplexPair(real: real, imag: imaginary))
            block += 1
        }
        // Couplings leave repeated blocks semisimple while exercising a nonnormal Schur pair.
        for row in 0..<scalarCount {
            for column in scalarCount..<n {
                s[row + column * n] = Double((row + column) % 5 - 2) / 64
                t[row + column * n] = Double((2 * row + column) % 3 - 1) / 128
            }
        }
        // Signed permutations preserve exact rank for n=3; rounded rational rotations do not.
        let left = singular && n == 3
            ? fromRows([[0, 1, 0], [0, 0, -1], [1, 0, 0]])
            : familyOrthogonal(dimension: n, phase: 0)
        let right = singular && n == 3
            ? fromRows([[0, 0, 1], [-1, 0, 0], [0, 1, 0]])
            : familyOrthogonal(dimension: n, phase: 1)
        return (multiply(multiply(left, s, n), transpose(right, n), n),
                multiply(multiply(left, t, n), transpose(right, n), n), expected)
    }

    private func familyOrthogonal(dimension n: Int, phase: Int) -> [Double] {
        var result = identity(n)
        if n == 3 {
            // A 3/5, 4/5 rotation is nontrivial; its rounding is part of the input perturbation.
            for (first, second) in [(0, 1), (1, 2), (0, 2)] {
                for column in 0..<n {
                    let a = result[first + column * n]
                    let b = result[second + column * n]
                    result[first + column * n] = 0.6 * a + 0.8 * b
                    result[second + column * n] = -0.8 * a + 0.6 * b
                }
            }
        } else {
            var starts = Array(stride(from: 0, through: n - 4, by: 3))
            if starts.last != n - 4 { starts.append(n - 4) }
            for pass in 0..<2 {
                let ordered = (pass + phase).isMultiple(of: 2) ? starts : Array(starts.reversed())
                for start in ordered {
                    for column in 0..<n {
                        let a = result[start + column * n]
                        let b = result[start + 1 + column * n]
                        let c = result[start + 2 + column * n]
                        let d = result[start + 3 + column * n]
                        result[start + column * n] = (a + b + c + d) * 0.5
                        result[start + 1 + column * n] = (a - b + c - d) * 0.5
                        result[start + 2 + column * n] = (a + b - c - d) * 0.5
                        result[start + 3 + column * n] = (a - b - c + d) * 0.5
                    }
                }
                if pass == 0 {
                    for row in 0..<n where (row + phase) % 3 == 1 {
                        for column in 0..<n { result[row + column * n] = -result[row + column * n] }
                    }
                }
            }
        }
        var permuted = result
        for column in 0..<n {
            for row in 0..<n {
                let sign = (row + phase).isMultiple(of: 3) ? -1.0 : 1.0
                permuted[row + column * n] = sign * result[(row + phase + 1) % n + column * n]
            }
        }
        return permuted
    }

    private func transform(_ a: [Double], _ b: [Double], dimension n: Int) -> (a: [Double], b: [Double]) {
        let left = fromRows([[0.5, 0.5, 0.5, 0.5], [0.5, -0.5, 0.5, -0.5],
                             [0.5, 0.5, -0.5, -0.5], [0.5, -0.5, -0.5, 0.5]])
        var right = left
        for row in 0..<n { right[row + 3 * n] = -right[row + 3 * n] }
        return (multiply(multiply(left, a, n), transpose(right, n), n),
                multiply(multiply(left, b, n), transpose(right, n), n))
    }

    private func checkedDecomposition(_ a: [Double], _ b: [Double], dimension n: Int) throws
        -> GeneralizedSchurDecomposition {
        let result = try GeneralizedSchur.decompose(matrixA: a, matrixB: b, dimension: n)
        try #require(result.s.count == n * n)
        try #require(result.t.count == n * n)
        try #require(result.q.count == n * n)
        try #require(result.z.count == n * n)
        #expect(result.eigenvalues.count == n)
        let bound = Double(n) * 4096 * Double.ulpOfOne
        let scaledA = a.map { scaled($0, by: result.aScaleExponent) }
        let scaledB = b.map { scaled($0, by: result.bScaleExponent) }
        let reconstructedA = multiply(multiply(result.q, result.s, n), transpose(result.z, n), n)
        let reconstructedB = multiply(multiply(result.q, result.t, n), transpose(result.z, n), n)
        #expect(relativeMatrixError(reconstructedA, scaledA) <= bound)
        #expect(relativeMatrixError(reconstructedB, scaledB) <= bound)
        for factor in [result.q, result.z] {
            let gram = multiply(transpose(factor, n), factor, n)
            #expect(relativeMatrixError(gram, identity(n)) <= bound)
        }
        let sScale = max(result.s.map { abs($0) }.max() ?? 0, .leastNormalMagnitude)
        let tScale = max(result.t.map { abs($0) }.max() ?? 0, .leastNormalMagnitude)
        for column in 0..<n {
            for row in 0..<n {
                if row > column + 1 { #expect(abs(result.s[row + column * n]) / sScale <= bound) }
                if row > column { #expect(abs(result.t[row + column * n]) / tScale <= bound) }
            }
        }
        for value in result.eigenvalues {
            #expect(value.alphaReal.isFinite && value.alphaImag.isFinite && value.beta.isFinite)
            #expect(value.alphaReal != 0 || value.alphaImag != 0 || value.beta != 0)
        }
        return result
    }

    private func expectSpectrum(_ actual: [ComplexPair], expected: [ComplexPair]) {
        #expect(actual.count == expected.count)
        var remaining = actual
        let scale = max(expected.map { max(abs($0.real), abs($0.imag)) }.max() ?? 0,
                        Double.leastNormalMagnitude)
        for value in expected {
            guard let index = remaining.indices.min(by: {
                distance(remaining[$0], value) < distance(remaining[$1], value)
            }) else { return }
            let candidate = remaining.remove(at: index)
            #expect(distance(candidate, value) / scale < 1e-11)
        }
    }

    private func distance(_ a: ComplexPair, _ b: ComplexPair) -> Double {
        max(abs(a.real - b.real), abs(a.imag - b.imag))
    }

    private func relativeMatrixError(_ actual: [Double], _ expected: [Double]) -> Double {
        let norm = max(expected.map { abs($0) }.max() ?? 0, .leastNormalMagnitude)
        return zip(actual, expected).map { abs($0 - $1) / norm }.max() ?? 0
    }

    private func scaled(_ value: Double, by exponent: Int) -> Double {
        value == 0 ? value : Double(sign: value.sign, exponent: value.exponent + exponent,
                                   significand: value.significand)
    }

    private func fromRows(_ rows: [[Double]]) -> [Double] {
        rows.indices.flatMap { column in rows.indices.map { row in rows[row][column] } }
    }

    private func identity(_ n: Int) -> [Double] {
        var result = Array(repeating: 0.0, count: n * n)
        for index in 0..<n { result[index + index * n] = 1 }
        return result
    }

    private func transpose(_ matrix: [Double], _ n: Int) -> [Double] {
        (0..<n).flatMap { column in (0..<n).map { row in matrix[column + row * n] } }
    }

    private func multiply(_ a: [Double], _ b: [Double], _ n: Int) -> [Double] {
        var result = Array(repeating: 0.0, count: n * n)
        for column in 0..<n {
            for row in 0..<n {
                for inner in 0..<n { result[row + column * n] += a[row + inner * n] * b[inner + column * n] }
            }
        }
        return result
    }

    private func runControlled(_ pair: (a: [Double], b: [Double]), control: SchurTestControl) throws {
        let result = try GeneralizedSchur.decompose(matrixA: pair.a, matrixB: pair.b, dimension: 4, control: control)
        expectSpectrum(try result.finiteEigenvalues(), expected: mixedSpectrum)
    }

    private func expectReleased(_ control: SchurTestControl) {
        let state = control.snapshot
        #expect(state.liveBytes == 0)
        #expect(state.reservations == state.releases)
        #expect(!state.invalidRelease)
    }
}

private final class SchurTestControl: LinearSolverExecutionControlling {
    enum Stop: Error, Equatable, Sendable { case work, cancelled, capacity }

    struct State: Sendable {
        var positiveCheckpoints = 0
        var admittedPositiveCheckpoints = 0
        var totalWork = 0
        var reservationAttempts = 0
        var reservations = 0
        var releases = 0
        var liveBytes = 0
        var peakBytes = 0
        var invalidRelease = false
    }

    private let state = Mutex(State())
    private let stop: Stop?
    private let stopAtPositiveCheckpoint: Int
    private let capacity: Int
    var snapshot: State { state.withLock { $0 } }

    init(stop: Stop? = nil, stopAtPositiveCheckpoint: Int = .max, capacity: Int = .max) {
        self.stop = stop
        self.stopAtPositiveCheckpoint = stopAtPositiveCheckpoint
        self.capacity = capacity
    }

    func checkpoint(workUnits: Int) throws {
        try state.withLock {
            #expect(workUnits >= 0)
            guard workUnits > 0 else { return }
            $0.positiveCheckpoints += 1
            if $0.positiveCheckpoints == stopAtPositiveCheckpoint, let stop { throw stop }
            $0.admittedPositiveCheckpoints += 1
            $0.totalWork += workUnits
        }
    }

    func reserveStorage(byteCount: Int) throws -> any Sendable {
        try state.withLock {
            $0.reservationAttempts += 1
            guard byteCount >= 0, byteCount <= capacity - $0.liveBytes else { throw Stop.capacity }
            $0.reservations += 1
            $0.liveBytes += byteCount
            $0.peakBytes = max($0.peakBytes, $0.liveBytes)
        }
        return Lease(owner: self, bytes: byteCount)
    }

    private final class Lease: Sendable {
        let owner: SchurTestControl
        let bytes: Int
        init(owner: SchurTestControl, bytes: Int) { self.owner = owner; self.bytes = bytes }
        deinit {
            owner.state.withLock {
                $0.invalidRelease = $0.invalidRelease || $0.liveBytes < bytes
                $0.liveBytes -= bytes
                $0.releases += 1
            }
        }
    }
}

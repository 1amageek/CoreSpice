import CoreSpiceCompile

/// S,T are the Schur pair of the independently scaled original matrices.
struct GeneralizedSchurDecomposition: Sendable {
    let s: [Double]
    let t: [Double]
    let q: [Double]
    let z: [Double]
    let aScaleExponent: Int
    let bScaleExponent: Int
    let eigenvalues: [HomogeneousEigenvalue]
    let sweepCount: Int
    let retainedWorkspace: (any Sendable)?

    var infiniteEigenvalueCount: Int {
        eigenvalues.reduce(0) { $0 + ($1.beta == 0 ? 1 : 0) }
    }

    func finiteEigenvalues(control: (any LinearSolverExecutionControlling)? = nil) throws -> [ComplexPair] {
        var finiteCount = 0
        for index in eigenvalues.indices {
            if index % 32 == 0 { try control?.checkpoint(workUnits: min(32, eigenvalues.count - index)) }
            if eigenvalues[index].beta != 0 { finiteCount += 1 }
        }
        var result = [ComplexPair]()
        result.reserveCapacity(finiteCount)
        for (index, entry) in eigenvalues.enumerated() {
            if index % 32 == 0 { try control?.checkpoint(workUnits: min(32, eigenvalues.count - index) * 8) }
            guard entry.beta != 0 else { continue }
            let real = entry.alphaReal / entry.beta
            let imag = entry.alphaImag / entry.beta
            guard real.isFinite, imag.isFinite else {
                throw GeneralizedSchurError.finiteProjectionOverflow(index: index)
            }
            result.append(ComplexPair(real: real, imag: imag))
        }
        return result
    }
}

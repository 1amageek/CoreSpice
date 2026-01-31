import CoreSpiceIR

/// A complex-valued quantity with real and imaginary parts.
public struct ComplexStampValue: Sendable {

    public var real: Double
    public var imag: Double

    public init(real: Double, imag: Double = 0) {
        self.real = real
        self.imag = imag
    }
}

/// Provides closure-based access to the complex MNA matrix and RHS vector.
///
/// Used during AC (small-signal) analysis where impedances and
/// admittances are complex-valued functions of frequency.
///
/// `ComplexMatrixStamper` is intentionally **not** `Sendable`. Stamping is
/// always single-threaded, so the closures can capture mutable local state
/// directly without synchronisation overhead.
public struct ComplexMatrixStamper {

    public var stampMatrix: (_ row: Int, _ col: Int, _ real: Double, _ imag: Double) -> Void
    public var stampRHS: (_ row: Int, _ real: Double, _ imag: Double) -> Void
    private let variableMap: [MNAVariable: Int]

    public init(
        variableMap: [MNAVariable: Int],
        stampMatrix: @escaping (_ row: Int, _ col: Int, _ real: Double, _ imag: Double) -> Void,
        stampRHS: @escaping (_ row: Int, _ real: Double, _ imag: Double) -> Void
    ) {
        self.variableMap = variableMap
        self.stampMatrix = stampMatrix
        self.stampRHS = stampRHS
    }

    // MARK: - Helpers

    /// Stamp a complex admittance between two nodes.
    ///
    /// Follows the same pattern as the real conductance stamp but
    /// with complex coefficients.
    public func stampAdmittance(node1: Node, node2: Node, real: Double, imag: Double) {
        let i = nodeIndex(node1)
        let j = nodeIndex(node2)

        if let i {
            stampMatrix(i, i, real, imag)
        }
        if let j {
            stampMatrix(j, j, real, imag)
        }
        if let i, let j {
            stampMatrix(i, j, -real, -imag)
            stampMatrix(j, i, -real, -imag)
        }
    }

    /// Stamp a complex voltage source with branch variable.
    public func stampVoltageSource(
        posNode: Node,
        negNode: Node,
        branch: Branch,
        real: Double,
        imag: Double
    ) {
        guard let bIdx = branchIndex(branch) else { return }
        let pIdx = nodeIndex(posNode)
        let nIdx = nodeIndex(negNode)

        if let pIdx {
            stampMatrix(pIdx, bIdx, 1.0, 0.0)
            stampMatrix(bIdx, pIdx, 1.0, 0.0)
        }
        if let nIdx {
            stampMatrix(nIdx, bIdx, -1.0, 0.0)
            stampMatrix(bIdx, nIdx, -1.0, 0.0)
        }

        stampRHS(bIdx, real, imag)
    }

    /// Stamp a complex current source.
    public func stampCurrentSource(posNode: Node, negNode: Node, real: Double, imag: Double) {
        if let pIdx = nodeIndex(posNode) {
            stampRHS(pIdx, real, imag)
        }
        if let nIdx = nodeIndex(negNode) {
            stampRHS(nIdx, -real, -imag)
        }
    }

    // MARK: - Index Lookup

    /// Returns the matrix index for a node voltage variable, or `nil` for ground.
    public func nodeIndex(_ node: Node) -> Int? {
        if node == .ground { return nil }
        return variableMap[.nodeVoltage(node)]
    }

    /// Returns the matrix index for a branch current variable.
    public func branchIndex(_ branch: Branch) -> Int? {
        variableMap[.branchCurrent(branch)]
    }
}

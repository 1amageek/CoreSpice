import CoreSpiceIR

/// Provides closure-based access to the MNA matrix and right-hand side vector.
///
/// Devices call the stamp helpers during analysis setup to contribute
/// their linearised element equations to the global system.
///
/// `MatrixStamper` is intentionally **not** `Sendable`. Stamping is always
/// single-threaded, so the closures can capture mutable local state directly
/// without synchronisation overhead.
public struct MatrixStamper {

    public var stampMatrix: (_ row: Int, _ col: Int, _ value: Double) -> Void
    public var stampRHS: (_ row: Int, _ value: Double) -> Void
    private let variableMap: [MNAVariable: Int]

    public init(
        variableMap: [MNAVariable: Int],
        stampMatrix: @escaping (_ row: Int, _ col: Int, _ value: Double) -> Void,
        stampRHS: @escaping (_ row: Int, _ value: Double) -> Void
    ) {
        self.variableMap = variableMap
        self.stampMatrix = stampMatrix
        self.stampRHS = stampRHS
    }

    // MARK: - Helpers

    /// Stamp a conductance `g` between two nodes.
    ///
    /// The standard MNA conductance stamp adds `g` to the diagonal
    /// entries and subtracts `g` from the off-diagonal entries.
    /// Ground-node entries are skipped.
    public func stampConductance(node1: Node, node2: Node, conductance: Double) {
        let i = nodeIndex(node1)
        let j = nodeIndex(node2)

        if let i {
            stampMatrix(i, i, conductance)
        }
        if let j {
            stampMatrix(j, j, conductance)
        }
        if let i, let j {
            stampMatrix(i, j, -conductance)
            stampMatrix(j, i, -conductance)
        }
    }

    /// Stamp a voltage source between two nodes through a branch variable.
    ///
    /// Encodes the KVL equation `V(pos) - V(neg) = voltage` and
    /// the branch current contributions to the node KCL equations.
    public func stampVoltageSource(posNode: Node, negNode: Node, branch: Branch, voltage: Double) {
        guard let bIdx = branchIndex(branch) else { return }
        let pIdx = nodeIndex(posNode)
        let nIdx = nodeIndex(negNode)

        // KCL contributions: branch current enters positive, leaves negative
        if let pIdx {
            stampMatrix(pIdx, bIdx, 1.0)
            stampMatrix(bIdx, pIdx, 1.0)
        }
        if let nIdx {
            stampMatrix(nIdx, bIdx, -1.0)
            stampMatrix(bIdx, nIdx, -1.0)
        }

        // KVL: V(pos) - V(neg) = voltage
        stampRHS(bIdx, voltage)
    }

    /// Stamp a current source that injects `current` from `negNode` to `posNode`.
    ///
    /// Current enters the positive node and leaves the negative node.
    public func stampCurrentSource(posNode: Node, negNode: Node, current: Double) {
        if let pIdx = nodeIndex(posNode) {
            stampRHS(pIdx, current)
        }
        if let nIdx = nodeIndex(negNode) {
            stampRHS(nIdx, -current)
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

import CoreSpiceIR

/// Context provided to devices during the binding phase.
///
/// Binding transforms a structural `Instance` into a `BoundDevice`
/// that knows its matrix indices and has allocated any branch
/// variables it needs.
public struct BindingContext: Sendable {

    public let variableMap: [MNAVariable: Int]
    public let matrixDimension: Int
    private var nextBranchID: Int

    /// Closure for pre-resolving CSR value indices at bind time.
    ///
    /// When provided, devices can resolve CSR value indices during binding
    /// to bypass binary search during stamping.
    private let stampIndexResolver: (@Sendable (_ row: Int, _ col: Int) -> Int?)?

    public init(
        variableMap: [MNAVariable: Int],
        matrixDimension: Int,
        nextBranchID: Int = 0,
        stampIndexResolver: (@Sendable (_ row: Int, _ col: Int) -> Int?)? = nil
    ) {
        self.variableMap = variableMap
        self.matrixDimension = matrixDimension
        self.nextBranchID = nextBranchID
        self.stampIndexResolver = stampIndexResolver
    }

    /// Allocates a new branch variable for the MNA system.
    public mutating func allocateBranch() -> Branch {
        let b = Branch(id: nextBranchID)
        nextBranchID += 1
        return b
    }

    /// Returns the matrix index for a node voltage variable, or `nil` for ground.
    public func nodeIndex(_ node: Node) -> Int? {
        if node == .ground { return nil }
        return variableMap[.nodeVoltage(node)]
    }

    /// Returns the matrix index for a branch current variable.
    public func branchIndex(_ branch: Branch) -> Int? {
        variableMap[.branchCurrent(branch)]
    }

    /// Pre-resolves the CSR value index for a matrix position.
    ///
    /// Returns `nil` when no stamp index resolver is available
    /// or the position does not exist in the sparsity pattern.
    public func stampIndex(row: Int, col: Int) -> Int? {
        stampIndexResolver?(row, col)
    }
}

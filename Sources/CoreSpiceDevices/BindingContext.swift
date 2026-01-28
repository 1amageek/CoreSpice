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

    public init(
        variableMap: [MNAVariable: Int],
        matrixDimension: Int,
        nextBranchID: Int = 0
    ) {
        self.variableMap = variableMap
        self.matrixDimension = matrixDimension
        self.nextBranchID = nextBranchID
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
}

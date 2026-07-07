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
    private let branchesByName: [String: Branch]
    private var inductanceByBranch: [Branch: Double]

    /// Closure for pre-resolving CSR value indices at bind time.
    ///
    /// When provided, devices can resolve CSR value indices during binding
    /// to bypass binary search during stamping.
    private let stampIndexResolver: (@Sendable (_ row: Int, _ col: Int) -> Int?)?

    public init(
        variableMap: [MNAVariable: Int],
        matrixDimension: Int,
        nextBranchID: Int = 0,
        branchNames: [Branch: String] = [:],
        inductanceByBranch: [Branch: Double] = [:],
        stampIndexResolver: (@Sendable (_ row: Int, _ col: Int) -> Int?)? = nil
    ) {
        self.variableMap = variableMap
        self.matrixDimension = matrixDimension
        self.nextBranchID = nextBranchID
        self.branchesByName = Dictionary(
            branchNames.map { branch, name in
                (name.lowercased(), branch)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        self.inductanceByBranch = inductanceByBranch
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

    /// Returns a branch variable by its source-level instance name.
    public func branch(named name: String) -> Branch? {
        branchesByName[name.lowercased()]
    }

    /// Records the inductance carried by an inductor branch.
    public mutating func registerInductance(_ inductance: Double, for branch: Branch) {
        inductanceByBranch[branch] = inductance
    }

    /// Returns the inductance carried by an inductor branch.
    public func inductance(for branch: Branch) -> Double? {
        inductanceByBranch[branch]
    }

    /// Pre-resolves the CSR value index for a matrix position.
    ///
    /// Returns `nil` when no stamp index resolver is available
    /// or the position does not exist in the sparsity pattern.
    public func stampIndex(row: Int, col: Int) -> Int? {
        stampIndexResolver?(row, col)
    }
}

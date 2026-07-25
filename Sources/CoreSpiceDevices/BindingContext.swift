import CoreSpiceIR

/// Context provided to devices during the binding phase.
///
/// Binding transforms a structural `Instance` into a `BoundDevice`
/// that knows its matrix indices and has allocated any branch
/// variables it needs.
public struct BindingContext: Sendable {

    public let variableMap: [MNAVariable: Int]
    public let matrixDimension: Int
    public let operatingConditions: OperatingConditions
    private let availableBranches: [Branch]
    private var claimedBranches: Set<Branch>
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
        operatingConditions: OperatingConditions = .nominal,
        stampIndexResolver: (@Sendable (_ row: Int, _ col: Int) -> Int?)? = nil
    ) {
        self.variableMap = variableMap
        self.matrixDimension = matrixDimension
        self.operatingConditions = operatingConditions
        self.availableBranches = variableMap.keys.compactMap { variable -> Branch? in
            guard case .branchCurrent(let branch) = variable,
                  branch.id >= nextBranchID else {
                return nil
            }
            return branch
        }.sorted { $0.id < $1.id }
        self.claimedBranches = []
        self.branchesByName = Dictionary(
            branchNames.map { branch, name in
                (name.lowercased(), branch)
            },
            uniquingKeysWith: { existing, _ in existing }
        )
        self.inductanceByBranch = inductanceByBranch
        self.stampIndexResolver = stampIndexResolver
    }

    /// Claims the canonical branch owned by a device instance.
    ///
    /// Explicit ownership is preferred. Legacy programmatic IR without
    /// ownership metadata consumes the next unclaimed compiled branch.
    public mutating func claimBranch(
        for instance: Instance,
        ownedIndex: Int = 0
    ) throws -> Branch {
        let branch: Branch
        if !instance.ownedBranches.isEmpty {
            guard instance.ownedBranches.indices.contains(ownedIndex) else {
                throw DeviceBindingError.missingBranchVariable(
                    device: instance.name,
                    ownedIndex: ownedIndex
                )
            }
            branch = instance.ownedBranches[ownedIndex]
            guard variableMap[.branchCurrent(branch)] != nil else {
                throw DeviceBindingError.missingBranchVariable(
                    device: instance.name,
                    ownedIndex: ownedIndex
                )
            }
        } else {
            guard let next = availableBranches.first(where: {
                !claimedBranches.contains($0)
            }) else {
                throw DeviceBindingError.missingBranchVariable(
                    device: instance.name,
                    ownedIndex: ownedIndex
                )
            }
            branch = next
        }

        guard claimedBranches.insert(branch).inserted else {
            throw DeviceBindingError.duplicateBranchOwnership(
                device: instance.name,
                branchID: branch.id
            )
        }
        return branch
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

import CoreSpiceIR

/// Snapshot of the MNA solution at a given point.
///
/// Provides typed access to node voltages and branch currents
/// using the variable map that ties each `MNAVariable` to an
/// index in the solution vector.
public struct SolutionState: Sendable {

    public let variables: [Double]
    public let previousVariables: [Double]?
    public let twoPreviousVariables: [Double]?
    public let variableLowComponents: [Double]?
    public let previousVariableLowComponents: [Double]?
    public let twoPreviousVariableLowComponents: [Double]?
    private let variableMap: [MNAVariable: Int]

    public init(
        variables: [Double],
        previousVariables: [Double]? = nil,
        twoPreviousVariables: [Double]? = nil,
        variableMap: [MNAVariable: Int],
        variableLowComponents: [Double]? = nil,
        previousVariableLowComponents: [Double]? = nil,
        twoPreviousVariableLowComponents: [Double]? = nil
    ) {
        self.variables = variables
        self.previousVariables = previousVariables
        self.twoPreviousVariables = twoPreviousVariables
        self.variableMap = variableMap
        self.variableLowComponents = variableLowComponents
        self.previousVariableLowComponents = previousVariableLowComponents
        self.twoPreviousVariableLowComponents = twoPreviousVariableLowComponents
    }

    /// Creates a checked accepted-history view using the same private variable identities.
    internal func checkedPreviousSnapshot() throws -> SolutionState {
        guard let values = previousVariables, values.count == variables.count,
              values.allSatisfy(\.isFinite) else {
            throw DeviceBindingError.invalidParameterValue(device: "physicalResidual",
                parameter: "previousState", message: "A finite complete accepted history is required")
        }
        return SolutionState(variables: values, variableMap: variableMap, variableLowComponents: previousVariableLowComponents)
    }

    /// Returns the voltage at the given node.
    ///
    /// The ground node always returns 0. A missing variable indicates a
    /// binding invariant violation. Use `checkedVoltage(at:)` at input
    /// boundaries that require a structured failure.
    public func voltage(at node: Node) -> Double {
        if node == .ground { return 0.0 }
        guard let idx = variableMap[.nodeVoltage(node)] else {
            preconditionFailure("Missing bound node voltage for node \(node.id)")
        }
        precondition(
            idx >= 0 && idx < variables.count,
            "Bound node voltage index \(idx) is outside solution size \(variables.count)"
        )
        return variables[idx]
    }

    /// Returns the voltage at the given node, or throws when the node is not part of the solved state.
    ///
    /// The ground node always returns 0.
    public func checkedVoltage(at node: Node) throws -> Double {
        if node == .ground { return 0.0 }
        guard let idx = variableMap[.nodeVoltage(node)] else {
            throw SolutionStateAccessError.missingNodeVoltage(nodeID: node.id)
        }
        return try checkedValue(at: idx)
    }

    /// Returns the current through the given branch.
    ///
    /// A missing variable indicates a binding invariant violation. Use
    /// `checkedCurrent(through:)` at input boundaries that require a
    /// structured failure.
    public func current(through branch: Branch) -> Double {
        guard let idx = variableMap[.branchCurrent(branch)] else {
            preconditionFailure("Missing bound branch current for branch \(branch.id)")
        }
        precondition(
            idx >= 0 && idx < variables.count,
            "Bound branch current index \(idx) is outside solution size \(variables.count)"
        )
        return variables[idx]
    }

    /// Returns the current through the given branch, or throws when the branch is not part of the solved state.
    public func checkedCurrent(through branch: Branch) throws -> Double {
        guard let idx = variableMap[.branchCurrent(branch)] else {
            throw SolutionStateAccessError.missingBranchCurrent(branchID: branch.id)
        }
        return try checkedValue(at: idx)
    }

    /// Returns the voltage at the given node from the previous iteration.
    ///
    /// Falls back to the current voltage when no previous state exists.
    public func previousVoltage(at node: Node) -> Double {
        guard let prev = previousVariables else { return voltage(at: node) }
        if node == .ground { return 0.0 }
        guard let idx = variableMap[.nodeVoltage(node)] else {
            preconditionFailure("Missing bound node voltage for node \(node.id)")
        }
        precondition(
            idx >= 0 && idx < prev.count,
            "Bound node voltage index \(idx) is outside previous solution size \(prev.count)"
        )
        return prev[idx]
    }

    /// Returns the current through the given branch from the previous iteration.
    ///
    /// Falls back to the current value when no previous state exists.
    public func previousCurrent(through branch: Branch) -> Double {
        guard let prev = previousVariables else { return current(through: branch) }
        guard let idx = variableMap[.branchCurrent(branch)] else {
            preconditionFailure("Missing bound branch current for branch \(branch.id)")
        }
        precondition(
            idx >= 0 && idx < prev.count,
            "Bound branch current index \(idx) is outside previous solution size \(prev.count)"
        )
        return prev[idx]
    }

    /// Returns the voltage at the given node from two iterations ago.
    ///
    /// Falls back to `previousVoltage` when no two-previous state exists.
    public func twoPreviousVoltage(at node: Node) -> Double {
        guard let tp = twoPreviousVariables else { return previousVoltage(at: node) }
        if node == .ground { return 0.0 }
        guard let idx = variableMap[.nodeVoltage(node)] else {
            preconditionFailure("Missing bound node voltage for node \(node.id)")
        }
        precondition(
            idx >= 0 && idx < tp.count,
            "Bound node voltage index \(idx) is outside two-previous solution size \(tp.count)"
        )
        return tp[idx]
    }

    // MARK: - Index-Based Access (zero-cost, no dictionary lookup)

    /// Returns the current solution value at a pre-resolved index.
    public func value(at index: Int) -> Double {
        variables[index]
    }

    /// Returns the current solution value at a pre-resolved index.
    public func checkedValue(at index: Int) throws -> Double {
        guard index >= 0, index < variables.count else {
            throw SolutionStateAccessError.valueIndexOutOfBounds(index: index, count: variables.count)
        }
        return variables[index]
    }

    /// Checks that the solution map preserves the variable identity admitted at binding.
    func checkedBoundValue(at index: Int, for variable: MNAVariable) throws -> Double {
        guard let actual = variableMap[variable] else {
            switch variable {
            case .nodeVoltage(let node):
                throw SolutionStateAccessError.missingNodeVoltage(nodeID: node.id)
            case .branchCurrent(let branch):
                throw SolutionStateAccessError.missingBranchCurrent(branchID: branch.id)
            }
        }
        guard actual == index else {
            throw SolutionStateAccessError.variableIndexMismatch(expected: index, actual: actual)
        }
        return try checkedValue(at: index)
    }

    /// Returns the previous solution value at a pre-resolved index.
    ///
    /// Falls back to the current value when no previous state exists.
    public func previousValue(at index: Int) -> Double {
        guard let prev = previousVariables else { return variables[index] }
        return prev[index]
    }

    /// Returns the two-previous solution value at a pre-resolved index.
    ///
    /// Falls back to `previousValue` when no two-previous state exists.
    public func twoPreviousValue(at index: Int) -> Double {
        guard let tp = twoPreviousVariables else { return previousValue(at: index) }
        return tp[index]
    }
    /// Validates all represented coordinates before a precision-requested evaluation.
    public func validateCompensatedComponents() throws {
        try Self.validatePair(variables, variableLowComponents)
        if let previousVariables { try Self.validatePair(previousVariables, previousVariableLowComponents) }
        else if previousVariableLowComponents != nil { throw NumericalStateError.missingHighHistory }
        if let twoPreviousVariables { try Self.validatePair(twoPreviousVariables, twoPreviousVariableLowComponents) }
        else if twoPreviousVariableLowComponents != nil { throw NumericalStateError.missingHighHistory }
    }

    private static func validatePair(_ high: [Double], _ low: [Double]?) throws {
        if let low, low.count != high.count {
            throw NumericalStateError.lowComponentCountMismatch(expected: high.count, actual: low.count)
        }
        for index in high.indices { _ = try CompensatedValue(high: high[index], low: low?[index] ?? 0) }
    }

    public func checkedCompensatedValue(at index: Int) throws -> CompensatedValue {
        let high = try checkedValue(at: index)
        if let low = variableLowComponents, low.count != variables.count {
            throw NumericalStateError.lowComponentCountMismatch(expected: variables.count, actual: low.count)
        }
        return try CompensatedValue(high: high, low: variableLowComponents?[index] ?? 0)
    }

    /// Reads a normalized pair only when the private map preserves the exact prebound variable and row.
    ///
    /// Throws for missing/remapped node or branch identities, invalid storage or invalid components.
    /// Ground has no implicit bound row; use `checkedCompensatedVoltage(at:)` for ground zero.
    public func checkedBoundCompensatedValue(at index: Int, for variable: MNAVariable) throws -> CompensatedValue {
        _ = try checkedBoundValue(at: index, for: variable)
        return try checkedCompensatedValue(at: index)
    }

    public func checkedCompensatedVoltage(at node: Node) throws -> CompensatedValue {
        if node == .ground { return .zero }
        guard let index = variableMap[.nodeVoltage(node)] else {
            throw SolutionStateAccessError.missingNodeVoltage(nodeID: node.id)
        }
        return try checkedCompensatedValue(at: index)
    }

    public func checkedCompensatedCurrent(through branch: Branch) throws -> CompensatedValue {
        guard let index = variableMap[.branchCurrent(branch)] else {
            throw SolutionStateAccessError.missingBranchCurrent(branchID: branch.id)
        }
        return try checkedCompensatedValue(at: index)
    }

}

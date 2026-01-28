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
    private let variableMap: [MNAVariable: Int]

    public init(
        variables: [Double],
        previousVariables: [Double]? = nil,
        twoPreviousVariables: [Double]? = nil,
        variableMap: [MNAVariable: Int]
    ) {
        self.variables = variables
        self.previousVariables = previousVariables
        self.twoPreviousVariables = twoPreviousVariables
        self.variableMap = variableMap
    }

    /// Returns the voltage at the given node.
    ///
    /// The ground node always returns 0.
    public func voltage(at node: Node) -> Double {
        if node == .ground { return 0.0 }
        guard let idx = variableMap[.nodeVoltage(node)] else { return 0.0 }
        return variables[idx]
    }

    /// Returns the current through the given branch.
    public func current(through branch: Branch) -> Double {
        guard let idx = variableMap[.branchCurrent(branch)] else { return 0.0 }
        return variables[idx]
    }

    /// Returns the voltage at the given node from the previous iteration.
    ///
    /// Falls back to the current voltage when no previous state exists.
    public func previousVoltage(at node: Node) -> Double {
        guard let prev = previousVariables else { return voltage(at: node) }
        if node == .ground { return 0.0 }
        guard let idx = variableMap[.nodeVoltage(node)] else { return 0.0 }
        return prev[idx]
    }

    /// Returns the current through the given branch from the previous iteration.
    ///
    /// Falls back to the current value when no previous state exists.
    public func previousCurrent(through branch: Branch) -> Double {
        guard let prev = previousVariables else { return current(through: branch) }
        guard let idx = variableMap[.branchCurrent(branch)] else { return 0.0 }
        return prev[idx]
    }

    /// Returns the voltage at the given node from two iterations ago.
    ///
    /// Falls back to `previousVoltage` when no two-previous state exists.
    public func twoPreviousVoltage(at node: Node) -> Double {
        guard let tp = twoPreviousVariables else { return previousVoltage(at: node) }
        if node == .ground { return 0.0 }
        guard let idx = variableMap[.nodeVoltage(node)] else { return 0.0 }
        return tp[idx]
    }
}

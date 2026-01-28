import CoreSpiceIR

/// The result of a DC operating point analysis.
///
/// Provides typed access to node voltages and branch currents
/// from the converged MNA solution.
public struct DCResult: Sendable {

    /// The converged solution vector.
    public let variables: [Double]

    /// Mapping from MNA variables to indices in the solution vector.
    public let variableMap: [MNAVariable: Int]

    /// The number of Newton-Raphson iterations performed.
    public let iterations: Int

    public init(
        variables: [Double],
        variableMap: [MNAVariable: Int],
        iterations: Int
    ) {
        self.variables = variables
        self.variableMap = variableMap
        self.iterations = iterations
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
}

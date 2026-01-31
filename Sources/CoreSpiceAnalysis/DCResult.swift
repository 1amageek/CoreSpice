import CoreSpiceDevices
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

    /// Converged optical state at the DC operating point.
    /// `nil` when the circuit contains no optical devices.
    public let opticalState: OpticalState?

    public init(
        variables: [Double],
        variableMap: [MNAVariable: Int],
        iterations: Int,
        opticalState: OpticalState? = nil
    ) {
        self.variables = variables
        self.variableMap = variableMap
        self.iterations = iterations
        self.opticalState = opticalState
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

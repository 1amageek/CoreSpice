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
    ) throws {
        guard iterations >= 0 else {
            throw DCResultValidationError.negativeIterationCount(iterations)
        }
        for (index, value) in variables.enumerated() where !value.isFinite {
            throw DCResultValidationError.nonFiniteVariable(index: index, value: value)
        }
        var mappedIndices: Set<Int> = []
        for (variable, index) in variableMap {
            guard variables.indices.contains(index) else {
                throw DCResultValidationError.variableIndexOutOfBounds(
                    variable: variable,
                    index: index,
                    count: variables.count
                )
            }
            guard mappedIndices.insert(index).inserted else {
                throw DCResultValidationError.duplicateVariableIndex(index)
            }
        }
        self.variables = variables
        self.variableMap = variableMap
        self.iterations = iterations
        self.opticalState = opticalState
    }

    /// Returns the voltage at the given node.
    ///
    /// The ground node always returns 0.
    public func voltage(at node: Node) throws -> Double {
        if node == .ground { return 0.0 }
        guard let idx = variableMap[.nodeVoltage(node)] else {
            throw SolutionStateAccessError.missingNodeVoltage(nodeID: node.id)
        }
        return try value(at: idx)
    }

    /// Returns the voltage at the given node, or throws when the node is not part of the solved state.
    ///
    /// The ground node always returns 0.
    public func checkedVoltage(at node: Node) throws -> Double {
        try voltage(at: node)
    }

    /// Returns the current through the given branch.
    ///
    public func current(through branch: Branch) throws -> Double {
        guard let idx = variableMap[.branchCurrent(branch)] else {
            throw SolutionStateAccessError.missingBranchCurrent(branchID: branch.id)
        }
        return try value(at: idx)
    }

    /// Returns the current through the given branch, or throws when the branch is not part of the solved state.
    public func checkedCurrent(through branch: Branch) throws -> Double {
        try current(through: branch)
    }

    private func value(at index: Int) throws -> Double {
        guard variables.indices.contains(index) else {
            throw SolutionStateAccessError.valueIndexOutOfBounds(
                index: index,
                count: variables.count
            )
        }
        return variables[index]
    }
}

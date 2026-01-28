import CoreSpiceIR

/// The result of a transient (time-domain) analysis.
///
/// Contains the full time-domain trajectory of the circuit: a series
/// of time points and the corresponding MNA solution vectors.
public struct TransientResult: Sendable {

    /// The simulation time values at which solutions were saved.
    public let timePoints: [Double]

    /// Solution vectors, one per time point.
    ///
    /// `solutions[t][i]` is the value of MNA variable `i` at time
    /// `timePoints[t]`.
    public let solutions: [[Double]]

    /// Mapping from MNA variables to indices in each solution vector.
    public let variableMap: [MNAVariable: Int]

    /// Total number of accepted timesteps.
    public let timeSteps: Int

    /// Number of rejected (and retried) timesteps.
    public let rejectedSteps: Int

    public init(
        timePoints: [Double],
        solutions: [[Double]],
        variableMap: [MNAVariable: Int],
        timeSteps: Int,
        rejectedSteps: Int
    ) {
        self.timePoints = timePoints
        self.solutions = solutions
        self.variableMap = variableMap
        self.timeSteps = timeSteps
        self.rejectedSteps = rejectedSteps
    }

    /// Returns the voltage at the given node for a specific time index.
    ///
    /// Ground always returns 0.
    public func voltage(at node: Node, timeIndex: Int) -> Double {
        if node == .ground { return 0.0 }
        guard let idx = variableMap[.nodeVoltage(node)] else { return 0.0 }
        return solutions[timeIndex][idx]
    }

    /// Returns the full voltage waveform at the given node as time-value pairs.
    public func voltageWaveform(at node: Node) -> [(time: Double, value: Double)] {
        timePoints.enumerated().map { (idx, t) in
            (time: t, value: voltage(at: node, timeIndex: idx))
        }
    }
}

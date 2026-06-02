import CoreSpiceIR

/// The result of a transient (time-domain) analysis.
///
/// Contains the full time-domain trajectory of the circuit: a series
/// of time points and the corresponding MNA solution vectors.
public struct TransientResult: Sendable {

    /// The simulation time values at which solutions were saved.
    public let timePoints: [Double]

    /// Solution vectors, one per time point, stored in row-major order.
    public let solutionTrace: SolutionTrace

    /// Mapping from MNA variables to indices in each solution vector.
    public let variableMap: [MNAVariable: Int]

    /// Total number of accepted timesteps.
    public let timeSteps: Int

    /// Number of rejected (and retried) timesteps.
    public let rejectedSteps: Int

    public init(
        timePoints: [Double],
        solutionTrace: SolutionTrace,
        variableMap: [MNAVariable: Int],
        timeSteps: Int,
        rejectedSteps: Int
    ) {
        self.timePoints = timePoints
        self.solutionTrace = solutionTrace
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
        return solutionTrace.value(pointIndex: timeIndex, variableIndex: idx)
    }

    public func value(variableIndex: Int, timeIndex: Int) -> Double {
        solutionTrace.value(pointIndex: timeIndex, variableIndex: variableIndex)
    }

    public func withSolution<R>(
        at timeIndex: Int,
        _ body: (UnsafeBufferPointer<Double>) throws -> R
    ) rethrows -> R {
        try solutionTrace.withPoint(at: timeIndex, body)
    }

    /// Returns the full voltage waveform at the given node as time-value pairs.
    public func voltageWaveform(at node: Node) -> [(time: Double, value: Double)] {
        guard node != .ground else {
            return timePoints.map { (time: $0, value: 0.0) }
        }
        guard let variableIndex = variableMap[.nodeVoltage(node)] else { return [] }
        let column = solutionTrace.column(variableIndex: variableIndex)
        return timePoints.enumerated().map { (idx, t) in
            (time: t, value: column[idx])
        }
    }
}

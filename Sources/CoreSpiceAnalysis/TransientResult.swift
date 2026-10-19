import CoreSpiceIR
import CoreSpiceDevices

public enum TransientResultError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownNode(Node)

    public var description: String {
        switch self {
        case .unknownNode(let node):
            "Transient result does not contain node \(node.id)."
        }
    }
}

/// The result of a transient (time-domain) analysis.
///
/// Contains the full time-domain trajectory of the circuit: a series
/// of time points and the corresponding MNA solution vectors.
public struct TransientResult: Sendable, AnalysisResultStorageRetaining {
    package let retainedStorage: (any Sendable)?

    /// The simulation time values at which solutions were saved.
    public let timePoints: [Double]

    /// Solution vectors, one per time point, stored in row-major order.
    public let solutionTrace: SolutionTrace
    public let solutionLowTrace: SolutionTrace?

    /// Mapping from MNA variables to indices in each solution vector.
    public let variableMap: [MNAVariable: Int]

    /// Total number of accepted timesteps.
    public let timeSteps: Int

    /// Number of rejected (and retried) timesteps.
    public let rejectedSteps: Int

    public let operatingPoint: DCResult?
    public let acceptedSteps: [TransientAcceptedStep]

    public let executionStatistics: TransientExecutionStatistics?

    public init(
        timePoints: [Double],
        solutionTrace: SolutionTrace,
        variableMap: [MNAVariable: Int],
        timeSteps: Int,
        rejectedSteps: Int,
        executionStatistics: TransientExecutionStatistics? = nil,
        operatingPoint: DCResult? = nil,
        acceptedSteps: [TransientAcceptedStep] = [],
        solutionLowTrace: SolutionTrace? = nil
    ) throws {
        if let solutionLowTrace {
            guard solutionLowTrace.variableCount == solutionTrace.variableCount,
                  solutionLowTrace.pointCount == solutionTrace.pointCount else {
                throw AnalysisResultValidationError.countMismatch(field: "solutionLowTrace", expected: solutionTrace.pointCount, actual: solutionLowTrace.pointCount)
            }
            for point in 0..<solutionTrace.pointCount {
                try solutionTrace.withPoint(at: point) { high in
                    try solutionLowTrace.withPoint(at: point) { low in
                        for index in high.indices { _ = try CompensatedValue(high: high[index], low: low[index]) }
                    }
                }
            }
        }
        self.solutionLowTrace = solutionLowTrace
        guard timeSteps >= 0 else {
            throw AnalysisResultValidationError.negativeCount(
                field: "timeSteps",
                value: timeSteps
            )
        }
        guard rejectedSteps >= 0 else {
            throw AnalysisResultValidationError.negativeCount(
                field: "rejectedSteps",
                value: rejectedSteps
            )
        }
        guard !timePoints.isEmpty else {
            throw AnalysisResultValidationError.countMismatch(
                field: "timePoints",
                expected: 1,
                actual: 0
            )
        }
        guard timePoints.count == solutionTrace.pointCount else {
            throw AnalysisResultValidationError.countMismatch(
                field: "solutionTrace.pointCount",
                expected: timePoints.count,
                actual: solutionTrace.pointCount
            )
        }
        for (index, time) in timePoints.enumerated() {
            guard time.isFinite else {
                throw AnalysisResultValidationError.nonFiniteValue(
                    field: "timePoints",
                    index: index,
                    value: time
                )
            }
            if index > 0, time <= timePoints[index - 1] {
                throw AnalysisResultValidationError.nonIncreasingValue(
                    field: "timePoints",
                    index: index,
                    previous: timePoints[index - 1],
                    value: time
                )
            }
        }
        var usedIndices: Set<Int> = []
        for index in variableMap.values {
            guard index >= 0, index < solutionTrace.variableCount else {
                throw AnalysisResultValidationError.invalidVariableIndex(
                    index: index,
                    variableCount: solutionTrace.variableCount
                )
            }
            guard usedIndices.insert(index).inserted else {
                throw AnalysisResultValidationError.duplicateVariableIndex(index)
            }
        }
        if let operatingPoint, operatingPoint.variableMap != variableMap {
            throw AnalysisResultValidationError.variableMapMismatch
        }
        if solutionLowTrace != nil || !acceptedSteps.isEmpty {
            guard acceptedSteps.count == timeSteps, acceptedSteps.count == timePoints.count - 1 else {
                throw AnalysisResultValidationError.countMismatch(field: "acceptedSteps", expected: timePoints.count - 1, actual: acceptedSteps.count)
            }
            for (index, step) in acceptedSteps.enumerated() {
                _ = try CompensatedValue(high: step.timeStep, low: step.timeStepLowComponent)
                if let previous = step.previousTimeStep { _ = try CompensatedValue(high: previous, low: step.previousTimeStepLowComponent ?? 0) }
                else if step.previousTimeStepLowComponent != nil { throw NumericalStateError.missingHighHistory }
                if solutionLowTrace != nil {
                    let exact = try CompensatedValue(high: step.time).subtracting(CompensatedValue(high: timePoints[index]))
                    guard exact == (try CompensatedValue(high: step.timeStep, low: step.timeStepLowComponent)) else {
                        throw AnalysisResultValidationError.nonFiniteValue(field: "acceptedSteps.exactInterval", index: index, value: step.timeStep)
                    }
                }
                guard step.time == timePoints[index + 1], step.timeStep.isFinite, step.timeStep > 0,
                      abs((step.time - timePoints[index]) - step.timeStep) <= max(abs(step.time), step.timeStep) * 64 * Double.ulpOfOne,
                      step.previousTimeStep.map({ $0.isFinite && $0 > 0 }) ?? true else {
                    throw AnalysisResultValidationError.nonFiniteValue(field: "acceptedSteps", index: index, value: step.timeStep)
                }
            }
        }
        self.operatingPoint = operatingPoint
        self.acceptedSteps = acceptedSteps
        self.executionStatistics = executionStatistics
        self.timePoints = timePoints
        self.solutionTrace = solutionTrace
        self.variableMap = variableMap
        self.timeSteps = timeSteps
        self.rejectedSteps = rejectedSteps
        self.retainedStorage = nil
    }

    /// Returns the same numerical values while retaining their native invocation capacity.
    package func retainingStorage(_ owner: any Sendable) -> Self {
        Self(retaining: self, owner: owner)
    }

    private init(retaining result: Self, owner: any Sendable) {
        self.operatingPoint = result.operatingPoint?.retainingStorage(owner)
        self.acceptedSteps = result.acceptedSteps
        self.executionStatistics = result.executionStatistics
        self.timePoints = result.timePoints
        self.solutionTrace = result.solutionTrace
        self.solutionLowTrace = result.solutionLowTrace
        self.variableMap = result.variableMap
        self.timeSteps = result.timeSteps
        self.rejectedSteps = result.rejectedSteps
        self.retainedStorage = owner
    }

    /// Returns the voltage at the given node for a specific time index.
    ///
    /// Ground always returns 0.
    public func checkedVoltage(at node: Node, timeIndex: Int) throws -> Double {
        if node == .ground { return 0.0 }
        guard let idx = variableMap[.nodeVoltage(node)] else {
            throw TransientResultError.unknownNode(node)
        }
        return try solutionTrace.value(pointIndex: timeIndex, variableIndex: idx)
    }

    public func voltage(at node: Node, timeIndex: Int) throws -> Double {
        try checkedVoltage(at: node, timeIndex: timeIndex)
    }

    public func checkedCompensatedValue(variableIndex: Int, timeIndex: Int) throws -> CompensatedValue {
        try CompensatedValue(high: solutionTrace.value(pointIndex: timeIndex, variableIndex: variableIndex),
            low: solutionLowTrace?.value(pointIndex: timeIndex, variableIndex: variableIndex) ?? 0)
    }

    public func withCompensatedSolution<R>(at timeIndex: Int,
        _ body: (UnsafeBufferPointer<Double>, UnsafeBufferPointer<Double>?) throws -> R
    ) throws -> R {
        try solutionTrace.withPoint(at: timeIndex) { high in
            if let solutionLowTrace { return try solutionLowTrace.withPoint(at: timeIndex) { try body(high, $0) } }
            return try body(high, nil)
        }
    }

    public func checkedValue(variableIndex: Int, timeIndex: Int) throws -> Double {
        try solutionTrace.value(pointIndex: timeIndex, variableIndex: variableIndex)
    }

    public func value(variableIndex: Int, timeIndex: Int) throws -> Double {
        try checkedValue(variableIndex: variableIndex, timeIndex: timeIndex)
    }

    public func withSolution<R>(
        at timeIndex: Int,
        _ body: (UnsafeBufferPointer<Double>) throws -> R
    ) throws -> R {
        try solutionTrace.withPoint(at: timeIndex, body)
    }

    /// Returns the full voltage waveform at the given node as time-value pairs.
    public func checkedVoltageWaveform(at node: Node) throws -> [(time: Double, value: Double)] {
        guard node != .ground else {
            return timePoints.map { (time: $0, value: 0.0) }
        }
        guard let variableIndex = variableMap[.nodeVoltage(node)] else {
            throw TransientResultError.unknownNode(node)
        }
        let column = try solutionTrace.column(variableIndex: variableIndex)
        return timePoints.enumerated().map { (idx, t) in
            (time: t, value: column[idx])
        }
    }

    public func voltageWaveform(at node: Node) throws -> [(time: Double, value: Double)] {
        try checkedVoltageWaveform(at: node)
    }
}

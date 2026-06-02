import Foundation
import CoreSpiceIO

public enum WaveformBenchmarkFixture {
    public static func waveform(pointCount: Int = 12_000, variableCount: Int = 12) -> WaveformData {
        var sweepValues: [Double] = []
        sweepValues.reserveCapacity(pointCount)
        var rowMajorValues: [Double] = []
        rowMajorValues.reserveCapacity(pointCount * variableCount)

        for point in 0..<pointCount {
            let time = Double(point) * 1e-12
            sweepValues.append(time)
            for variable in 0..<variableCount {
                let phase = Double((point + 1) * (variable + 3)) * 0.000_001
                rowMajorValues.append(sin(phase) + Double(variable) * 0.125)
            }
        }

        return WaveformData(
            metadata: SimulationMetadata(
                title: "Benchmark",
                analysisType: .transient,
                pointCount: pointCount,
                variableCount: variableCount
            ),
            sweepVariable: .time(),
            sweepValues: sweepValues,
            variables: variables(count: variableCount),
            realRowMajorData: rowMajorValues,
            pointCount: pointCount,
            variableCount: variableCount
        )
    }

    public static func transientResult(pointCount: Int = 12_000, variableCount: Int = 12) -> TransientResult {
        var timePoints: [Double] = []
        timePoints.reserveCapacity(pointCount)
        var rowMajorValues: [Double] = []
        rowMajorValues.reserveCapacity(pointCount * variableCount)

        for point in 0..<pointCount {
            timePoints.append(Double(point) * 1e-12)
            for variable in 0..<variableCount {
                rowMajorValues.append(Double(point + variable) * 0.001)
            }
        }

        return TransientResult(
            timePoints: timePoints,
            solutionTrace: SolutionTrace(variableCount: variableCount, rowMajorValues: rowMajorValues),
            variableMap: variableMap(count: variableCount),
            timeSteps: max(pointCount - 1, 0),
            rejectedSteps: 0
        )
    }

    public static func topology(variableCount: Int = 12) -> CircuitTopology {
        let nodes = (1...variableCount).map { Node(id: $0) }
        return CircuitTopology(ir: CircuitIR(nodes: [.ground] + nodes, branches: [], instances: []))
    }

    public static func variableIndices(variableCount: Int = 12) -> [Int] {
        Array(2..<min(variableCount, 10))
    }

    public static func pointIndices(pointCount: Int = 12_000) -> [Int] {
        Array(stride(from: 0, to: pointCount, by: 2))
    }

    private static func variables(count: Int) -> [VariableDescriptor] {
        (1...count).map { VariableDescriptor.voltage(node: "\($0)", index: $0 - 1) }
    }

    private static func variableMap(count: Int) -> [MNAVariable: Int] {
        Dictionary(uniqueKeysWithValues: (1...count).map { index in
            (.nodeVoltage(Node(id: index)), index - 1)
        })
    }
}

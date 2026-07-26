import CoreSpiceIO

public enum BehavioralSourceBenchmarkOperations {
    public static func linearStampComparison() throws -> BenchmarkComparison {
        let output = Node(id: 1)
        let control = Node(id: 2)
        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(output): 0,
            .nodeVoltage(control): 1,
        ]
        let state = SolutionState(
            variables: [0, 0.5],
            variableMap: variableMap
        )
        let behavioralExpression = BehavioralExpression.binary(
            .multiply,
            .constant(1e-3),
            .variable(
                .nodeVoltage(positive: control, negative: .ground)
            )
        )
        let behavioralInstance = Instance(
            name: "B1",
            typeName: "behavioral_isource",
            nodes: [output, .ground],
            parameters: ["i": .behavioralExpression(behavioralExpression)],
            referencedNodes: [control]
        )
        let referenceInstance = Instance(
            name: "G1",
            typeName: "vccs",
            nodes: [output, .ground, control, .ground],
            parameters: ["g": .real(1e-3)]
        )
        let registry = DeviceRegistry.standard()
        var behavioralContext = BindingContext(
            variableMap: variableMap,
            matrixDimension: variableMap.count
        )
        var referenceContext = BindingContext(
            variableMap: variableMap,
            matrixDimension: variableMap.count
        )
        guard let behavioralDescriptor = registry.descriptor(
            for: behavioralInstance.typeName
        ), let referenceDescriptor = registry.descriptor(
            for: referenceInstance.typeName
        ) else {
            throw BenchmarkError.missingDeviceDescriptor
        }
        let behavioral = try behavioralDescriptor.bind(
            instance: behavioralInstance,
            context: &behavioralContext
        )
        let reference = try referenceDescriptor.bind(
            instance: referenceInstance,
            context: &referenceContext
        )

        let behavioralStamp = try BenchmarkRunner.measure(
            "behavioral.linearCurrentStamp",
            iterationsPerSample: 25_000
        ) {
            stamp(device: behavioral, state: state, variableMap: variableMap)
        }
        let referenceStamp = try BenchmarkRunner.measure(
            "behavioral.vccsReferenceStamp",
            iterationsPerSample: 25_000
        ) {
            stamp(device: reference, state: state, variableMap: variableMap)
        }

        return BenchmarkComparison(
            name: "behavioral source linear stamp",
            measured: behavioralStamp,
            baseline: referenceStamp,
            maximumRatio: 3,
            requirement: "Allocation-free scalar AD must keep a linear behavioral source within 3x of the specialized VCCS stamp."
        )
    }

    private static func stamp(
        device: any BoundDevice,
        state: SolutionState,
        variableMap: [MNAVariable: Int]
    ) -> Double {
        let accumulator = StampAccumulator()
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, column, value in
                accumulator.value += Double(row + column + 1) * value
            },
            stampRHS: { row, value in
                accumulator.value += Double(row + 1) * value
            }
        )
        device.stampDC(into: &stamper, state: state)
        return accumulator.value
    }
}

private final class StampAccumulator {
    var value = 0.0
}

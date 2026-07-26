import Foundation
import Testing
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

@Suite("Behavioral-source devices")
struct BehavioralSourceTests {
    @Test("Scalar automatic differentiation matches an independent analytic derivative")
    func automaticDifferentiationMatchesAnalyticDerivative() throws {
        let control = Node(id: 1)
        let expression = BehavioralExpression.binary(
            .add,
            .function(.sine, [
                .variable(.nodeVoltage(positive: control, negative: .ground)),
            ]),
            .binary(
                .power,
                .variable(.nodeVoltage(positive: control, negative: .ground)),
                .constant(2)
            )
        )
        let instance = Instance(
            name: "B1",
            typeName: "behavioral_isource",
            nodes: [Node(id: 2), .ground],
            parameters: ["i": .behavioralExpression(expression)],
            referencedNodes: [control]
        )
        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(control): 0,
            .nodeVoltage(Node(id: 2)): 1,
        ]
        let context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let evaluator = try BehavioralExpressionEvaluator(
            expression: expression,
            instance: instance,
            context: context
        )
        let state = SolutionState(variables: [0.5, 0], variableMap: variableMap)

        let evaluation = evaluator.evaluate(
            state: state,
            time: 0,
            differentiating: 0
        )

        #expect(abs(evaluation.value - (sin(0.5) + 0.25)) < 1e-12)
        #expect(abs(evaluation.derivative - (cos(0.5) + 1)) < 1e-12)
    }

    @Test("Integer powers of negative variables keep a finite derivative")
    func negativeBaseWithConstantExponentHasFiniteDerivative() throws {
        let control = Node(id: 1)
        let expression = BehavioralExpression.binary(
            .power,
            .variable(.nodeVoltage(positive: control, negative: .ground)),
            .constant(2)
        )
        let instance = Instance(
            name: "B1",
            typeName: "behavioral_isource",
            nodes: [Node(id: 2), .ground],
            parameters: ["i": .behavioralExpression(expression)],
            referencedNodes: [control]
        )
        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(control): 0,
            .nodeVoltage(Node(id: 2)): 1,
        ]
        let evaluator = try BehavioralExpressionEvaluator(
            expression: expression,
            instance: instance,
            context: BindingContext(variableMap: variableMap, matrixDimension: 2)
        )
        let state = SolutionState(variables: [-3, 0], variableMap: variableMap)

        let evaluation = evaluator.evaluate(
            state: state,
            time: 0,
            differentiating: 0
        )

        #expect(evaluation.value == 9)
        #expect(evaluation.derivative == -6)
    }

    @Test("Both behavioral output descriptors are registered")
    func registryContainsBothOutputKinds() {
        let registry = DeviceRegistry.standard()
        #expect(registry.descriptor(for: "behavioral_vsource") != nil)
        #expect(registry.descriptor(for: "behavioral_isource") != nil)
    }
}

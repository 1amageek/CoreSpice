import Testing
import CoreSpiceIR
@testable import CoreSpiceDevices

@Suite("Runtime semiconductor resistor")
struct RuntimeResistorTests {
    private let positive = Node(id: 1)
    private let negative = Node(id: 2)
    private let control = Node(id: 3)
    private let branch = Branch(id: 0)

    private var map: [MNAVariable: Int] {
        [.nodeVoltage(positive): 0, .nodeVoltage(negative): 1,
         .nodeVoltage(control): 2, .branchCurrent(branch): 3]
    }

    private func bind(_ expression: BehavioralExpression,
                      parameters: [String: ParameterValue] = [:],
                      conditions: OperatingConditions = .nominal,
                      policy: RuntimeResistorPolicy = .default,
                      variableMap: [MNAVariable: Int]? = nil,
                      referencedBranches: [Branch]? = nil,
                      model: ResolvedDeviceModel? = nil,
                      csr: Bool = false) throws -> any BoundDevice {
        var values = parameters
        values["r"] = .behavioralExpression(expression)
        let instance = Instance(name: "Rruntime", typeName: "resistor", nodes: [positive, negative],
            parameters: values, model: model, referencedBranches: referencedBranches ?? [branch])
        let csrResolver: @Sendable (Int, Int) -> Int? = { row, col in row * 4 + col }
        let resolver = csr ? csrResolver : nil
        var context = BindingContext(variableMap: variableMap ?? map, matrixDimension: (variableMap ?? map).count,
            operatingConditions: conditions, stampIndexResolver: resolver)
        return try ResistorDescriptor(runtimePolicy: policy).bind(instance: instance, context: &context)
    }

    private struct Stamp {
        var matrix: [[Double]] = Array(repeating: Array(repeating: 0, count: 4), count: 4)
        var rhs: [Double] = Array(repeating: 0, count: 4)
    }

    private func stamp(_ bound: any BoundDevice, values: [Double] = [2, 0.5, 0.25, 0.01],
                       time: Double? = nil, ac: Bool = false, csr: Bool = false,
                       stateMap: [MNAVariable: Int]? = nil) throws -> Stamp {
        var result = Stamp()
        let state = SolutionState(variables: values, variableMap: stateMap ?? map)
        if ac {
            var stamper = ComplexMatrixStamper(variableMap: map,
                stampMatrix: { row, col, real, imag in
                    #expect(imag == 0)
                    result.matrix[row][col] += real
                }, stampRHS: { _, _, _ in Issue.record("Runtime AC must not emit a large-signal source") })
            try bound.stampAC(into: &stamper, state: state, omega: 1)
        } else {
            var stamper = MatrixStamper(variableMap: map,
                stampMatrix: { row, col, value in
                    if csr { Issue.record("Prebound runtime CSR index was not used") }
                    result.matrix[row][col] += value
                }, stampRHS: { row, value in result.rhs[row] += value },
                stampValue: csr ? { index, value in result.matrix[index / 4][index % 4] += value } : nil)
            if let time {
                try bound.stampTransient(into: &stamper, state: state,
                    integration: .init(method: .trapezoidal, timeStep: 0.1, currentTime: time))
            } else {
                try bound.stampDC(into: &stamper, state: state)
            }
        }
        return result
    }

    private func close(_ actual: Double, _ expected: Double) {
        #expect(abs(actual - expected) <= 1e-12 * max(abs(expected), 1e-8))
    }

    @Test func fullAnalyticalJacobianAndEquivalentCurrentReachesCoordinateCSRAndAC() throws {
        // R = 100 + 10*(Vp - Vn) + 20*Vc + 50*Ib, independently differentiated below.
        let expression = BehavioralExpression.binary(.add,
            .binary(.add, .constant(100), .binary(.multiply, .constant(10),
                .variable(.nodeVoltage(positive: positive, negative: negative)))),
            .binary(.add, .binary(.multiply, .constant(20),
                .variable(.nodeVoltage(positive: control, negative: .ground))),
                .binary(.multiply, .constant(50), .variable(.branchCurrentReference(0)))))
        let values = [2.0, 0.5, 0.25, 0.01]
        let resistance = 120.5
        let voltage = 1.5
        let current = 3 * voltage / resistance
        let derivatives = [3 / resistance - 3 * voltage * 10 / (resistance * resistance),
            -3 / resistance + 3 * voltage * 10 / (resistance * resistance),
            -3 * voltage * 20 / (resistance * resistance),
            -3 * voltage * 50 / (resistance * resistance)]
        let equivalent = current - zip(derivatives, values).reduce(0) { $0 + $1.0 * $1.1 }
        for csr in [false, true] {
            let bound = try bind(expression, parameters: ["m": .real(3)], csr: csr)
            let dc = try stamp(bound, values: values, csr: csr)
            let ac = try stamp(bound, values: values, ac: true)
            let transient = try stamp(bound, values: values, time: 2, csr: csr)
            for index in 0..<4 {
                close(dc.matrix[0][index], derivatives[index])
                close(dc.matrix[1][index], -derivatives[index])
                close(ac.matrix[0][index], derivatives[index])
                close(transient.matrix[0][index], derivatives[index])
            }
            close(dc.rhs[0], -equivalent)
            close(dc.rhs[1], equivalent)
            close(zip(dc.matrix[0], values).reduce(0) { $0 + $1.0 * $1.1 } - dc.rhs[0], current)
            #expect(dc.matrix[2].allSatisfy { $0 == 0 })
        }
    }

    @Test func ambientTemperatureAndDistinctMainAuxiliaryNominalsAndMultiplicity() throws {
        let expression = BehavioralExpression.binary(.add, .constant(100), .variable(.ambientTemperatureCelsius))
        let warm = try OperatingConditions(temperatureCelsius: 77, nominalTemperatureCelsius: 17)
        let alternative = try OperatingConditions(temperatureCelsius: 77, nominalTemperatureCelsius: 27)
        let parameters: [String: ParameterValue] = ["tc1": .real(0.001), "tc2": .real(0.00001),
            "m": .real(4), "noisy": .integer(1)]
        let first = try bind(expression, parameters: parameters, conditions: warm)
        let second = try bind(expression, parameters: parameters, conditions: alternative)
        let mainFactor = 1 + 0.001 * 50 + 0.00001 * 50 * 50
        close(try stamp(first).matrix[0][0], 4 / (177 * mainFactor))
        close(try stamp(second).matrix[0][0], 4 / (177 * mainFactor))
        for (bound, delta) in [(first, 60.0), (second, 50.0)] {
            let sources = try #require(bound as? any NoisyDevice).noiseContributions(
                state: .init(variables: [2, 0.5, 0.25, 0.01], variableMap: map), frequency: 10)
            #expect(sources.count == 1)
            let factor = 1 + 0.001 * delta + 0.00001 * delta * delta
            #expect(abs(sources[0].currentSpectralDensity / (4 * 1.380649e-23 * 350.15 / (177 * factor)) - 1) < 1e-12)
        }
        let cool = try bind(expression, conditions: .nominal)
        close(try stamp(cool).matrix[0][0], 1 / 127.0)
    }

    @Test func noiseDefaultSourceOverrideAndNoIntrinsicMultiplier() throws {
        let expression = BehavioralExpression.binary(.multiply, .constant(1000),
            .binary(.add, .constant(1), .variable(.nodeVoltage(positive: positive, negative: .ground))))
        let defaultEnabled = try RuntimeResistorPolicy(defaultNoisy: true)
        for (policy, flag, expected) in [(RuntimeResistorPolicy.default, nil as Double?, 0),
            (.default, 1.0, 1), (defaultEnabled, nil, 1), (defaultEnabled, 0.0, 0)] {
            var parameters: [String: ParameterValue] = ["m": .real(4)]
            if let flag { parameters["noise"] = .real(flag) }
            let bound = try bind(expression, parameters: parameters, policy: policy)
            let noise = try #require(bound as? any NoisyDevice).noiseContributions(
                state: .init(variables: [2, 0.5, 0.25, 0.01], variableMap: map), frequency: 1)
            #expect(noise.count == expected)
            if expected == 1 {
                #expect(abs(noise[0].currentSpectralDensity / (4 * 1.380649e-23 * 300.15 / 3000) - 1) < 1e-12)
            }
        }
    }

    @Test func transientUsesActualTimeWithoutHistoryOrTimeZeroConvergence() throws {
        let expression = BehavioralExpression.binary(.multiply, .constant(100), .variable(.time))
        let bound = try bind(expression)
        for time in [0.25, 1, 2, 0.5] {
            close(try stamp(bound, time: time).matrix[0][0], 1 / (100 * time))
        }
        #expect(throws: DeviceBindingError.self) { _ = try stamp(bound) }
        #expect(throws: DeviceBindingError.self) { _ = try stamp(bound, time: .infinity) }
        let state = SolutionState(variables: [2, 0.5, 0.25, 0.01], variableMap: map)
        guard case .converged = bound.checkConvergence(state: state, previousState: state) else {
            Issue.record("Memoryless device must leave actual-time residual ownership to the solver")
            return
        }
    }

    @Test func malformedArityAndMissingTopologyAreTypedBindingFailures() throws {
        for expression in [BehavioralExpression.function(.sine, []), .function(.power, [.constant(1)]),
            .function(.clamp, [.constant(1), .constant(2)]), .function(.minimum, []),
            .function(.sine, [.constant(1), .constant(2)]),
            .variable(.branchCurrentReference(-1)), .variable(.branchCurrentReference(1)),
            .variable(.nodeVoltage(positive: Node(id: 99), negative: .ground)), .constant(.infinity)] {
            #expect(throws: DeviceBindingError.self) { _ = try bind(expression) }
        }
        #expect(throws: DeviceBindingError.self) {
            _ = try bind(.constant(100), variableMap: [.nodeVoltage(positive): 0, .branchCurrent(branch): 1])
        }
        #expect(throws: DeviceBindingError.self) {
            _ = try bind(.variable(.branchCurrentReference(0)), referencedBranches: [Branch(id: 99)])
        }
    }

    @Test func invalidStateCannotTrapOrBeHiddenByFiniteComparisons() throws {
        let expression = BehavioralExpression.binary(.add, .constant(100),
            .variable(.nodeVoltage(positive: control, negative: .ground)))
        let bound = try bind(expression)
        #expect(throws: SolutionStateAccessError.self) { _ = try stamp(bound, values: [1]) }
        var absentControl = map
        absentControl[.nodeVoltage(control)] = nil
        #expect(throws: SolutionStateAccessError.self) { _ = try stamp(bound, stateMap: absentControl) }
        var absentTerminal = map
        absentTerminal[.nodeVoltage(positive)] = nil
        #expect(throws: SolutionStateAccessError.self) { _ = try stamp(bound, stateMap: absentTerminal) }
        #expect(throws: DeviceBindingError.self) { _ = try stamp(bound, values: [2, 0.5, .nan, 0.01]) }
        var swapped = map
        swapped[.nodeVoltage(positive)] = 1
        swapped[.nodeVoltage(negative)] = 0
        #expect(throws: SolutionStateAccessError.self) { _ = try stamp(bound, stateMap: swapped) }
        var movedControl = map
        movedControl[.nodeVoltage(control)] = 3
        #expect(throws: SolutionStateAccessError.self) { _ = try stamp(bound, stateMap: movedControl) }

        let branchBound = try bind(.binary(.add, .constant(100), .variable(.branchCurrentReference(0))))
        var absentBranch = map
        absentBranch[.branchCurrent(branch)] = nil
        #expect(throws: SolutionStateAccessError.self) { _ = try stamp(branchBound, stateMap: absentBranch) }
        let masked = try bind(.binary(.add, .constant(100),
            .binary(.greaterThan, .function(.exponential, [.constant(1000)]), .constant(1))))
        #expect(throws: DeviceBindingError.self) { _ = try stamp(masked) }
        let minimum = try bind(.function(.minimum, [.constant(100), .function(.exponential, [.constant(1000)])]))
        #expect(throws: DeviceBindingError.self) { _ = try stamp(minimum) }
    }

    @Test func nonpositiveResistanceCurrentDerivativeAndNoiseOverflowRefuse() throws {
        for value in [0.0, -1] {
            let bound = try bind(.constant(value))
            #expect(throws: DeviceBindingError.self) { _ = try stamp(bound) }
        }
        let nonfinite = try bind(.function(.exponential, [.constant(1000)]))
        #expect(throws: DeviceBindingError.self) { _ = try stamp(nonfinite) }
        let overflowingCurrent = try bind(.constant(0.1))
        #expect(throws: DeviceBindingError.self) { _ = try stamp(overflowingCurrent, values: [.greatestFiniteMagnitude, 0, 0, 0]) }
        let overflowingDerivative = try bind(.binary(.add, .constant(1),
            .binary(.multiply, .constant(1e300), .variable(.nodeVoltage(positive: control, negative: .ground)))))
        #expect(throws: DeviceBindingError.self) { _ = try stamp(overflowingDerivative, values: [1e20, 0, 0, 0]) }
        let overflowingAD = try bind(.binary(.add, .constant(100), .binary(.multiply, .constant(1e308),
            .function(.sine, [.binary(.multiply, .constant(2), .variable(.nodeVoltage(positive: control, negative: .ground)))]))))
        #expect(throws: DeviceBindingError.self) { _ = try stamp(overflowingAD, values: [1, 0, 0, 0]) }
        let tiny = try bind(.constant(.leastNonzeroMagnitude), parameters: ["m": .real(.leastNonzeroMagnitude), "noise": .real(1)],
            conditions: OperatingConditions(temperatureKelvin: 1e308))
        let noise = try #require(tiny as? any NoisyDevice)
        #expect(throws: DeviceBindingError.self) {
            _ = try noise.noiseContributions(state: .init(variables: [1, 0, 0, 0], variableMap: map), frequency: 1)
        }
    }

    @Test func unsupportedSourceParametersModelsAliasesAndTemperatureFactorsRefuse() throws {
        for key in ["ac", "temp", "dtemp", "tce", "scale", "l", "w", "kf", "af", "tnom", "unknown"] {
            #expect(throws: DeviceBindingError.self) { _ = try bind(.constant(100), parameters: [key: .real(0)]) }
        }
        let invalidParameters: [[String: ParameterValue]] = [["tc": .real(1), "tc1": .real(2)],
            ["noisy": .real(0), "noise": .real(1)], ["noisy": .real(0.5)], ["m": .real(0)],
            ["m": .real(.infinity)], ["tc1": .string("invalid")], ["resistance": .real(1)], ["R": .real(1)]]
        for parameters in invalidParameters {
            #expect(throws: DeviceBindingError.self) { _ = try bind(.constant(100), parameters: parameters) }
        }
        #expect(throws: DeviceBindingError.self) {
            _ = try bind(.constant(100), model: ResolvedDeviceModel(name: "discarded", typeName: "resistor", parameters: [:]))
        }
        #expect(throws: DeviceBindingError.self) {
            _ = try bind(.constant(100), parameters: ["tc1": .real(-0.02)],
                conditions: OperatingConditions(temperatureCelsius: 77))
        }
        let conditions = try OperatingConditions(temperatureCelsius: 27, nominalTemperatureCelsius: 17)
        #expect(throws: DeviceBindingError.self) {
            _ = try bind(.constant(100), parameters: ["tc1": .real(-0.1), "noise": .real(1)], conditions: conditions)
        }
        _ = try bind(.constant(100), parameters: ["tc1": .real(-0.1), "noise": .real(0)], conditions: conditions)
    }

    @Test func policyRejectsInvalidCeilingsAndOverflowAtConstruction() throws {
        #expect(throws: RuntimeResistorPolicyError.self) { _ = try RuntimeResistorPolicy(maxASTNodes: 0) }
        #expect(throws: RuntimeResistorPolicyError.self) { _ = try RuntimeResistorPolicy(maxASTDepth: 65) }
        #expect(throws: RuntimeResistorPolicyError.self) { _ = try RuntimeResistorPolicy(maxDependencies: 0) }
        #expect(throws: RuntimeResistorPolicyError.self) { _ = try RuntimeResistorPolicy(maxEvaluationWork: 0) }
        #expect(throws: RuntimeResistorPolicyError.self) { _ = try RuntimeResistorPolicy(maxASTNodes: Int.max) }
        #expect(throws: RuntimeResistorPolicyError.self) { _ = try RuntimeResistorPolicy(maxDependencies: Int.max) }
        let defaults = RuntimeResistorPolicy.default
        #expect(defaults.maxASTNodes == 4096 && defaults.maxASTDepth == 64)
        #expect(defaults.maxDependencies == 256 && defaults.maxEvaluationWork == 1_052_672)
    }

    @Test func nodeDepthDependencyAndWorkBoundsAdmitBoundaryAndRejectNext() throws {
        var depth = BehavioralExpression.constant(100)
        for _ in 1..<64 { depth = .unary(.plus, depth) }
        close(try stamp(bind(depth)).matrix[0][0], 0.01)
        #expect(throws: DeviceBindingError.self) { _ = try bind(.unary(.plus, depth)) }
        let nodes = BehavioralExpression.function(.minimum, Array(repeating: .constant(100), count: 4095))
        close(try stamp(bind(nodes)).matrix[0][0], 0.01)
        #expect(throws: DeviceBindingError.self) {
            _ = try bind(.function(.minimum, Array(repeating: .constant(100), count: 4096)))
        }
        let expression = BehavioralExpression.binary(.add, .constant(100),
            .variable(.nodeVoltage(positive: control, negative: .ground)))
        let exactWork = try RuntimeResistorPolicy(maxASTNodes: 3, maxASTDepth: 2,
            maxDependencies: 3, maxEvaluationWork: 12)
        close(try stamp(bind(expression, policy: exactWork)).matrix[0][0], 1 / 100.25)
        #expect(throws: DeviceBindingError.self) {
            _ = try bind(expression, policy: RuntimeResistorPolicy(maxEvaluationWork: 11))
        }
        #expect(throws: DeviceBindingError.self) {
            _ = try bind(expression, policy: RuntimeResistorPolicy(maxDependencies: 2))
        }
        #expect(throws: DeviceBindingError.self) {
            _ = try bind(.constant(100), policy: RuntimeResistorPolicy(maxASTNodes: 1, maxDependencies: 1))
        }
    }

    @Test func dependencyDefaultCeilingIncludesPortsAndASTReferences() throws {
        let controls = (3...256).map { Node(id: $0) }
        var variableMap: [MNAVariable: Int] = [.nodeVoltage(positive): 0, .nodeVoltage(negative): 1]
        for (offset, node) in controls.enumerated() { variableMap[.nodeVoltage(node)] = offset + 2 }
        let expression = BehavioralExpression.function(.maximum, [.constant(100)] + controls.map {
            .variable(.nodeVoltage(positive: $0, negative: .ground))
        })
        _ = try bind(expression, variableMap: variableMap, referencedBranches: [])
        let extra = Node(id: 257)
        variableMap[.nodeVoltage(extra)] = 256
        #expect(throws: DeviceBindingError.self) {
            _ = try bind(.binary(.add, expression, .variable(.nodeVoltage(positive: extra, negative: .ground))),
                variableMap: variableMap, referencedBranches: [])
        }
    }

    @Test func negativeModuloQuotientMatchesItsAnalyticalJacobian() throws {
        let expression = BehavioralExpression.binary(.add, .constant(1000),
            .binary(.modulo, .constant(5), .variable(.nodeVoltage(positive: control, negative: .ground))))
        let bound = try bind(expression)
        let result = try stamp(bound, values: [2, 0.5, -2, 0.01])
        close(result.matrix[0][0], 1 / 1001)
        close(result.matrix[0][2], -3 / (1001 * 1001))
    }

    @Test func finiteTimeOnlyValueAtVerticalSlopeDoesNotInventSolutionDerivative() throws {
        let expression = BehavioralExpression.binary(.add, .constant(100),
            .function(.squareRoot, [.variable(.time)]))
        let bound = try bind(expression)
        close(try stamp(bound, time: 0).matrix[0][0], 0.01)
        close(try stamp(bound, time: 1).matrix[0][0], 1 / 101)
        let controlled = try bind(.binary(.add, .constant(100),
            .function(.squareRoot, [.variable(.nodeVoltage(positive: control, negative: .ground))])))
        #expect(throws: DeviceBindingError.self) { _ = try stamp(controlled, values: [2, 0.5, 0, 0.01]) }
    }

    @Test func evaluatorValueOnlyGroundDerivativeIsZeroAndAmbientSourceBehaviorSurvives() throws {
        let instance = Instance(name: "Bcheck", typeName: "behavioralCurrentSource", nodes: [positive, .ground], parameters: [:])
        let context = BindingContext(variableMap: map, matrixDimension: 4)
        let evaluator = try BehavioralExpressionEvaluator(expression: .variable(.nodeVoltage(positive: positive, negative: .ground)),
            instance: instance, context: context)
        let state = SolutionState(variables: [2, 0.5, 0.25, 0.01], variableMap: map)
        #expect(evaluator.evaluate(state: state, time: 0).derivative == 0)
        #expect(try evaluator.evaluateChecked(state: state, time: 0).derivative == 0)
        let ambient = try BehavioralExpressionEvaluator(expression: .variable(.ambientTemperatureCelsius), instance: instance, context: context)
        close(ambient.evaluate(state: state, time: 0).value, 27)
        #expect(ambient.evaluate(state: state, time: 0, differentiating: 0).derivative == 0)
    }
}

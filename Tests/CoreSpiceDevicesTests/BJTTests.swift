import Testing
import Synchronization
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

/// Thread-safe collector for matrix stamp entries used in tests.
private final class BJTStampCollector: Sendable {
    private let _matrix = Mutex<[(Int, Int, Double)]>([])
    private let _rhs = Mutex<[(Int, Double)]>([])

    func addMatrix(_ r: Int, _ c: Int, _ v: Double) {
        _matrix.withLock { $0.append((r, c, v)) }
    }
    func addRHS(_ r: Int, _ v: Double) {
        _rhs.withLock { $0.append((r, v)) }
    }
    var matrixEntries: [(Int, Int, Double)] { _matrix.withLock { $0 } }
    var rhsEntries: [(Int, Double)] { _rhs.withLock { $0 } }

    func matrixSum(row: Int, col: Int) -> Double {
        matrixEntries.filter { $0.0 == row && $0.1 == col }.map { $0.2 }.reduce(0, +)
    }
    func rhsSum(row: Int) -> Double {
        rhsEntries.filter { $0.0 == row }.map { $0.1 }.reduce(0, +)
    }
}

@Suite("BJT Tests")
struct BJTTests {

    @Test func bjtRegistered() {
        let registry = DeviceRegistry.standard()
        #expect(registry.descriptor(for: "npn") != nil)
        #expect(registry.descriptor(for: "pnp") != nil)
    }

    @Test func npnDescriptorPortNames() {
        let desc = NPNDescriptor()
        #expect(desc.portNames == ["collector", "base", "emitter"])
        #expect(desc.typeName == "npn")
    }

    @Test func pnpDescriptorPortNames() {
        let desc = PNPDescriptor()
        #expect(desc.portNames == ["collector", "base", "emitter"])
        #expect(desc.typeName == "pnp")
    }

    @Test func npnBinding() throws {
        let desc = NPNDescriptor()
        let collector = Node(id: 1)
        let base = Node(id: 2)
        let emitter = Node(id: 3)
        let instance = Instance(
            name: "Q1",
            typeName: "npn",
            nodes: [collector, base, emitter],
            parameters: ["bf": .real(200)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(collector): 0,
            .nodeVoltage(base): 1,
            .nodeVoltage(emitter): 2
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let bound = try desc.bind(instance: instance, context: &context)
        #expect(bound.instance.name == "Q1")
    }

    @Test func bjtModelParametersDefaults() {
        let params = BJTModelParameters()
        #expect(params.polarity == .npn)
        #expect(params.saturationCurrent == 1e-16)
        #expect(params.forwardBeta == 100)
        #expect(params.reverseBeta == 1)
        #expect(params.forwardEmissionCoefficient == 1.0)
        #expect(params.reverseEmissionCoefficient == 1.0)
    }

    @Test func bjtModelParametersPNP() {
        let params = BJTModelParameters(polarity: .pnp, forwardBeta: 50)
        #expect(params.polarity == .pnp)
        #expect(params.forwardBeta == 50)
    }

    @Test func bjtThermalVoltage() {
        let params = BJTModelParameters(nominalTemperature: 300.15)
        let vt = params.thermalVoltage
        // Vt = kT/q ≈ 0.0259V at 300K
        #expect(abs(vt - 0.0259) < 0.001)
    }

    @Test func bjtForwardAlpha() {
        let params = BJTModelParameters(forwardBeta: 100)
        let alpha = params.forwardAlpha
        // alpha = beta / (beta + 1) = 100/101 ≈ 0.99
        #expect(abs(alpha - 0.99009) < 0.001)
    }

    @Test func npnForwardActiveStamp() throws {
        let desc = NPNDescriptor()
        let collector = Node(id: 1)
        let base = Node(id: 2)
        let emitter = Node(id: 3)
        let instance = Instance(
            name: "Q1",
            typeName: "npn",
            nodes: [collector, base, emitter],
            parameters: ["is": .real(1e-15), "bf": .real(100)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(collector): 0,
            .nodeVoltage(base): 1,
            .nodeVoltage(emitter): 2
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let bound = try desc.bind(instance: instance, context: &context)

        let collector_ = BJTStampCollector()

        // Forward active: Vc = 5V, Vb = 0.7V, Ve = 0V
        // Vbe = 0.7V, Vbc = 0.7-5 = -4.3V (reverse biased)
        let state = SolutionState(variables: [5.0, 0.7, 0.0], variableMap: variableMap)
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector_.addMatrix(r, c, v) },
            stampRHS: { r, v in collector_.addRHS(r, v) }
        )

        bound.stampDC(into: &stamper, state: state)

        // Should have stamps at various positions
        #expect(collector_.matrixEntries.count > 0)

        // Transconductance should create stamps from base to collector
        // gm stamps: collector row should have entries for base column
        let gmContribution = collector_.matrixSum(row: 0, col: 1)
        #expect(gmContribution != 0)
    }

    @Test func npnCutoffStamp() throws {
        let desc = NPNDescriptor()
        let collector = Node(id: 1)
        let base = Node(id: 2)
        let emitter = Node(id: 3)
        let instance = Instance(
            name: "Q1",
            typeName: "npn",
            nodes: [collector, base, emitter],
            parameters: ["is": .real(1e-15), "bf": .real(100)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(collector): 0,
            .nodeVoltage(base): 1,
            .nodeVoltage(emitter): 2
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let bound = try desc.bind(instance: instance, context: &context)

        let collector_ = BJTStampCollector()

        // Cutoff: Vc = 5V, Vb = 0V, Ve = 0V
        // Vbe = 0V (no forward bias)
        let state = SolutionState(variables: [5.0, 0.0, 0.0], variableMap: variableMap)
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector_.addMatrix(r, c, v) },
            stampRHS: { r, v in collector_.addRHS(r, v) }
        )

        bound.stampDC(into: &stamper, state: state)

        // Should still have stamps (gmin conductances)
        #expect(collector_.matrixEntries.count > 0)
    }

    @Test func bjtConvergenceCheck() throws {
        let desc = NPNDescriptor()
        let collector = Node(id: 1)
        let base = Node(id: 2)
        let emitter = Node(id: 3)
        let instance = Instance(
            name: "Q1",
            typeName: "npn",
            nodes: [collector, base, emitter],
            parameters: [:]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(collector): 0,
            .nodeVoltage(base): 1,
            .nodeVoltage(emitter): 2
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let bound = try desc.bind(instance: instance, context: &context)

        // Same state - should converge
        let state1 = SolutionState(variables: [5.0, 0.7, 0.0], variableMap: variableMap)
        let state2 = SolutionState(variables: [5.0, 0.7, 0.0], variableMap: variableMap)
        let result = bound.checkConvergence(state: state1, previousState: state2)
        if case .converged = result {
            #expect(true)
        } else {
            #expect(Bool(false), "Should converge when states are identical")
        }

        // Different base voltages - should not converge
        let state3 = SolutionState(variables: [5.0, 0.7, 0.0], variableMap: variableMap)
        let state4 = SolutionState(variables: [5.0, 0.5, 0.0], variableMap: variableMap)
        let result2 = bound.checkConvergence(state: state3, previousState: state4)
        if case .notConverged = result2 {
            #expect(true)
        } else {
            #expect(Bool(false), "Should not converge when voltages differ significantly")
        }
    }

    @Test func pnpForwardActiveStamp() throws {
        let desc = PNPDescriptor()
        let collector = Node(id: 1)
        let base = Node(id: 2)
        let emitter = Node(id: 3)
        let instance = Instance(
            name: "Q1",
            typeName: "pnp",
            nodes: [collector, base, emitter],
            parameters: ["is": .real(1e-15), "bf": .real(100)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(collector): 0,
            .nodeVoltage(base): 1,
            .nodeVoltage(emitter): 2
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let bound = try desc.bind(instance: instance, context: &context)

        let collector_ = BJTStampCollector()

        // PNP forward active: Ve = 5V, Vb = 4.3V, Vc = 0V
        // Veb = 5-4.3 = 0.7V (forward biased)
        let state = SolutionState(variables: [0.0, 4.3, 5.0], variableMap: variableMap)
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector_.addMatrix(r, c, v) },
            stampRHS: { r, v in collector_.addRHS(r, v) }
        )

        bound.stampDC(into: &stamper, state: state)

        // Should have stamps
        #expect(collector_.matrixEntries.count > 0)
    }

    @Test func npnWithGroundEmitter() throws {
        let desc = NPNDescriptor()
        let collector = Node(id: 1)
        let base = Node(id: 2)
        let emitter = Node.ground

        let instance = Instance(
            name: "Q1",
            typeName: "npn",
            nodes: [collector, base, emitter],
            parameters: [:]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(collector): 0,
            .nodeVoltage(base): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try desc.bind(instance: instance, context: &context)

        let collector_ = BJTStampCollector()
        let state = SolutionState(variables: [5.0, 0.7], variableMap: variableMap)
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector_.addMatrix(r, c, v) },
            stampRHS: { r, v in collector_.addRHS(r, v) }
        )

        bound.stampDC(into: &stamper, state: state)

        // Should have stamps (ground emitter means some indices will be nil)
        #expect(collector_.matrixEntries.count > 0)
    }

    @Test func bjtEarlyEffect() throws {
        // Test that output conductance increases with Early voltage
        let desc = NPNDescriptor()
        let collector = Node(id: 1)
        let base = Node(id: 2)
        let emitter = Node(id: 3)

        // BJT with finite Early voltage
        let instanceWithEarly = Instance(
            name: "Q1",
            typeName: "npn",
            nodes: [collector, base, emitter],
            parameters: ["is": .real(1e-15), "bf": .real(100), "vaf": .real(100)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(collector): 0,
            .nodeVoltage(base): 1,
            .nodeVoltage(emitter): 2
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let bound = try desc.bind(instance: instanceWithEarly, context: &context)

        let collector_ = BJTStampCollector()
        let state = SolutionState(variables: [5.0, 0.7, 0.0], variableMap: variableMap)
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector_.addMatrix(r, c, v) },
            stampRHS: { r, v in collector_.addRHS(r, v) }
        )

        bound.stampDC(into: &stamper, state: state)

        // Output conductance go should contribute to (collector, collector) stamp
        let goCont = collector_.matrixSum(row: 0, col: 0)
        #expect(goCont > 0)
    }
}

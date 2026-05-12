import Testing
import Synchronization
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

/// Thread-safe collector for matrix stamp entries used in tests.
private final class DiodeStampCollector: Sendable {
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

@Suite("Diode Tests")
struct DiodeTests {

    @Test func diodeRegistered() {
        let registry = DeviceRegistry.standard()
        #expect(registry.descriptor(for: "diode") != nil)
    }

    @Test func diodeDescriptorPortNames() {
        let desc = DiodeDescriptor()
        #expect(desc.portNames == ["anode", "cathode"])
        #expect(desc.typeName == "diode")
    }

    @Test func diodeBinding() throws {
        let desc = DiodeDescriptor()
        let anode = Node(id: 1)
        let cathode = Node(id: 2)
        let instance = Instance(
            name: "D1",
            typeName: "diode",
            nodes: [anode, cathode],
            parameters: ["is": .real(1e-14)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(anode): 0,
            .nodeVoltage(cathode): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try desc.bind(instance: instance, context: &context)
        #expect(bound.instance.name == "D1")
    }

    @Test func diodeModelParametersDefaults() {
        let params = DiodeModelParameters()
        #expect(params.saturationCurrent == 1e-14)
        #expect(params.emissionCoefficient == 1.0)
        #expect(params.seriesResistance == 0.0)
        #expect(params.junctionCapacitance == 0.0)
        #expect(params.junctionPotential == 1.0)
        #expect(params.gradingCoefficient == 0.5)
    }

    @Test func diodeThermalVoltage() {
        let params = DiodeModelParameters(nominalTemperature: 300.15)
        let vt = params.thermalVoltage
        // Vt = kT/q ≈ 0.0259V at 300K
        #expect(abs(vt - 0.0259) < 0.001)
    }

    @Test func diodeForwardBiasStamp() throws {
        let desc = DiodeDescriptor()
        let anode = Node(id: 1)
        let cathode = Node(id: 2)
        let instance = Instance(
            name: "D1",
            typeName: "diode",
            nodes: [anode, cathode],
            parameters: ["is": .real(1e-12)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(anode): 0,
            .nodeVoltage(cathode): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try desc.bind(instance: instance, context: &context)

        let collector = DiodeStampCollector()

        // Forward bias: Va = 0.7V, Vc = 0V, Vd = 0.7V
        let state = SolutionState(variables: [0.7, 0.0], variableMap: variableMap)
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector.addMatrix(r, c, v) },
            stampRHS: { r, v in collector.addRHS(r, v) }
        )

        bound.stampDC(into: &stamper, state: state)

        // Should have conductance stamps at all four positions
        #expect(collector.matrixEntries.count >= 4)

        // Conductance should be positive
        let g00 = collector.matrixSum(row: 0, col: 0)
        let g11 = collector.matrixSum(row: 1, col: 1)
        #expect(g00 > 0)
        #expect(g11 > 0)

        // Off-diagonal should be negative
        let g01 = collector.matrixSum(row: 0, col: 1)
        let g10 = collector.matrixSum(row: 1, col: 0)
        #expect(g01 < 0)
        #expect(g10 < 0)
    }

    @Test func diodeReverseBiasStamp() throws {
        let desc = DiodeDescriptor()
        let anode = Node(id: 1)
        let cathode = Node(id: 2)
        let instance = Instance(
            name: "D1",
            typeName: "diode",
            nodes: [anode, cathode],
            parameters: ["is": .real(1e-12)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(anode): 0,
            .nodeVoltage(cathode): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try desc.bind(instance: instance, context: &context)

        let collector = DiodeStampCollector()

        // Reverse bias: Va = 0V, Vc = 5V, Vd = -5V
        let state = SolutionState(variables: [0.0, 5.0], variableMap: variableMap)
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector.addMatrix(r, c, v) },
            stampRHS: { r, v in collector.addRHS(r, v) }
        )

        bound.stampDC(into: &stamper, state: state)

        // Should still have stamps (for gmin and small reverse conductance)
        #expect(collector.matrixEntries.count >= 4)

        // Conductance should be small but positive (gmin)
        let g00 = collector.matrixSum(row: 0, col: 0)
        #expect(g00 > 0)
    }

    @Test func diodeConvergenceCheck() throws {
        let desc = DiodeDescriptor()
        let anode = Node(id: 1)
        let cathode = Node(id: 2)
        let instance = Instance(
            name: "D1",
            typeName: "diode",
            nodes: [anode, cathode],
            parameters: [:]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(anode): 0,
            .nodeVoltage(cathode): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try desc.bind(instance: instance, context: &context)

        // Same state - should converge
        let state1 = SolutionState(variables: [0.7, 0.0], variableMap: variableMap)
        let state2 = SolutionState(variables: [0.7, 0.0], variableMap: variableMap)
        let result = bound.checkConvergence(state: state1, previousState: state2)
        #expect(result.isConverged)

        // Different states - may not converge
        let state3 = SolutionState(variables: [0.7, 0.0], variableMap: variableMap)
        let state4 = SolutionState(variables: [0.5, 0.0], variableMap: variableMap)
        let result2 = bound.checkConvergence(state: state3, previousState: state4)
        if case .notConverged(let maxDelta, let deviceName) = result2 {
            #expect(maxDelta > 0)
            #expect(deviceName == "D1")
        } else {
            #expect(Bool(false), "Should not converge when voltages differ significantly")
        }
    }

    @Test func diodeExponentialCharacteristic() throws {
        // Verify the exponential I-V relationship
        let desc = DiodeDescriptor()
        let anode = Node(id: 1)
        let cathode = Node(id: 2)

        let isat = 1e-12
        let instance = Instance(
            name: "D1",
            typeName: "diode",
            nodes: [anode, cathode],
            parameters: ["is": .real(isat), "n": .real(1.0)]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(anode): 0,
            .nodeVoltage(cathode): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try desc.bind(instance: instance, context: &context)

        // At Vd = 0.6V, current should be significant
        let collector1 = DiodeStampCollector()
        let state1 = SolutionState(variables: [0.6, 0.0], variableMap: variableMap)
        var stamper1 = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector1.addMatrix(r, c, v) },
            stampRHS: { r, v in collector1.addRHS(r, v) }
        )
        bound.stampDC(into: &stamper1, state: state1)
        let gd1 = collector1.matrixSum(row: 0, col: 0)

        // At Vd = 0.7V, conductance should be higher (exponential increase)
        let collector2 = DiodeStampCollector()
        let state2 = SolutionState(variables: [0.7, 0.0], variableMap: variableMap)
        var stamper2 = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector2.addMatrix(r, c, v) },
            stampRHS: { r, v in collector2.addRHS(r, v) }
        )
        bound.stampDC(into: &stamper2, state: state2)
        let gd2 = collector2.matrixSum(row: 0, col: 0)

        // Conductance should increase with voltage (exponential)
        #expect(gd2 > gd1)
    }

    @Test func diodeWithGroundCathode() throws {
        let desc = DiodeDescriptor()
        let anode = Node(id: 1)
        let cathode = Node.ground

        let instance = Instance(
            name: "D1",
            typeName: "diode",
            nodes: [anode, cathode],
            parameters: [:]
        )

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(anode): 0
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 1)
        let bound = try desc.bind(instance: instance, context: &context)

        let collector = DiodeStampCollector()
        let state = SolutionState(variables: [0.7], variableMap: variableMap)
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector.addMatrix(r, c, v) },
            stampRHS: { r, v in collector.addRHS(r, v) }
        )

        bound.stampDC(into: &stamper, state: state)

        // Only anode index should be stamped (cathode is ground)
        let g00 = collector.matrixSum(row: 0, col: 0)
        #expect(g00 > 0)
    }
}

private extension ConvergenceResult {
    var isConverged: Bool {
        if case .converged = self {
            return true
        }
        return false
    }
}

import Testing
import Synchronization
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

/// Thread-safe collector for matrix stamp entries used in tests.
private final class StampCollector: Sendable {
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
}

@Suite("CoreSpiceDevices Tests")
struct CoreSpiceDevicesTests {

    @Test func deviceRegistryStandard() {
        let registry = DeviceRegistry.standard()
        #expect(registry.descriptor(for: "resistor") != nil)
        #expect(registry.descriptor(for: "capacitor") != nil)
        #expect(registry.descriptor(for: "inductor") != nil)
        #expect(registry.descriptor(for: "vsource") != nil)
        #expect(registry.descriptor(for: "isource") != nil)
        #expect(registry.descriptor(for: "unknown_device") == nil)
    }

    @Test func resistorBinding() throws {
        let registry = DeviceRegistry.standard()
        let desc = registry.descriptor(for: "resistor")!

        let n1 = Node(id: 1)
        let n2 = Node(id: 2)
        let instance = Instance(name: "R1", typeName: "resistor", nodes: [n1, n2],
                                parameters: ["r": .real(1000)])

        var variableMap: [MNAVariable: Int] = [
            .nodeVoltage(n1): 0,
            .nodeVoltage(n2): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let bound = try desc.bind(instance: instance, context: &context)
        #expect(bound.instance.name == "R1")
    }

    @Test func resistorStampDC() throws {
        let n1 = Node(id: 1)
        let n2 = Node(id: 2)
        let instance = Instance(name: "R1", typeName: "resistor", nodes: [n1, n2],
                                parameters: ["r": .real(1000)])

        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(n1): 0,
            .nodeVoltage(n2): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 2)
        let desc = ResistorDescriptor()
        let bound = try desc.bind(instance: instance, context: &context)

        let collector = StampCollector()

        let state = SolutionState(variables: [5.0, 3.0], variableMap: variableMap)
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { r, c, v in collector.addMatrix(r, c, v) },
            stampRHS: { r, v in collector.addRHS(r, v) }
        )

        bound.stampDC(into: &stamper, state: state)

        // Resistor stamps conductance g = 1/1000 = 0.001
        // Should have stamps at (0,0)+=g, (1,1)+=g, (0,1)-=g, (1,0)-=g
        #expect(collector.matrixEntries.count >= 4)
    }

    @Test func convergenceResultConverged() {
        let result = ConvergenceResult.converged
        if case .converged = result {
            #expect(true)
        } else {
            #expect(Bool(false), "Expected converged")
        }
    }

    @Test func waveformDC() {
        let wf = Waveform.dc(5.0)
        #expect(wf.value(at: 0) == 5.0)
        #expect(wf.value(at: 1.0) == 5.0)
        #expect(wf.value(at: 100.0) == 5.0)
    }

    @Test func waveformSine() {
        let wf = Waveform.sine(offset: 0, amplitude: 1.0, frequency: 1.0, delay: 0, phase: 0)
        let v0 = wf.value(at: 0)
        let vQuarter = wf.value(at: 0.25)
        // At t=0: sin(0) = 0 → offset + amplitude * sin(2π*f*t) = 0
        #expect(abs(v0) < 1e-10)
        // At t=0.25: sin(π/2) = 1 → amplitude * 1.0 = 1.0
        #expect(abs(vQuarter - 1.0) < 1e-10)
    }

    @Test func integrationStateCoefficient() {
        let be = IntegrationState(method: .backwardEuler, timeStep: 1e-3, currentTime: 0)
        #expect(abs(be.coefficient - 1000.0) < 1e-6)

        let trap = IntegrationState(method: .trapezoidal, timeStep: 1e-3, currentTime: 0)
        #expect(abs(trap.coefficient - 2000.0) < 1e-6)
    }
}

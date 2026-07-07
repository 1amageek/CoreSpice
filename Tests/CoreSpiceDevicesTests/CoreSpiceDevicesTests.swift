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

    func matrixSum(row: Int, col: Int) -> Double {
        matrixEntries.filter { $0.0 == row && $0.1 == col }.map { $0.2 }.reduce(0, +)
    }

    func rhsSum(row: Int) -> Double {
        rhsEntries.filter { $0.0 == row }.map { $0.1 }.reduce(0, +)
    }
}

private final class ComplexStampCollector: Sendable {
    private let _matrix = Mutex<[(Int, Int, Double, Double)]>([])
    private let _rhs = Mutex<[(Int, Double, Double)]>([])

    func addMatrix(_ r: Int, _ c: Int, _ real: Double, _ imag: Double) {
        _matrix.withLock { $0.append((r, c, real, imag)) }
    }

    func addRHS(_ r: Int, _ real: Double, _ imag: Double) {
        _rhs.withLock { $0.append((r, real, imag)) }
    }

    func matrixSum(row: Int, col: Int) -> (real: Double, imag: Double) {
        _matrix.withLock { values in
            values
                .filter { $0.0 == row && $0.1 == col }
                .reduce((real: 0.0, imag: 0.0)) { partial, entry in
                    (partial.real + entry.2, partial.imag + entry.3)
                }
        }
    }
}

@Suite("CoreSpiceDevices Tests")
struct CoreSpiceDevicesTests {

    @Test func deviceRegistryStandard() {
        let registry = DeviceRegistry.standard()
        #expect(registry.descriptor(for: "resistor") != nil)
        #expect(registry.descriptor(for: "capacitor") != nil)
        #expect(registry.descriptor(for: "inductor") != nil)
        #expect(registry.descriptor(for: "mutual") != nil)
        #expect(registry.descriptor(for: "vsource") != nil)
        #expect(registry.descriptor(for: "isource") != nil)
        #expect(registry.descriptor(for: "unknown_device") == nil)
    }

    @Test func resistorBinding() throws {
        let registry = DeviceRegistry.standard()
        let desc = try #require(registry.descriptor(for: "resistor"))

        let n1 = Node(id: 1)
        let n2 = Node(id: 2)
        let instance = Instance(name: "R1", typeName: "resistor", nodes: [n1, n2],
                                parameters: ["r": .real(1000)])

        let variableMap: [MNAVariable: Int] = [
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
        #expect(result.isConverged)
    }

    @Test func solutionStateCheckedAccessRejectsMissingVariables() throws {
        let knownNode = Node(id: 1)
        let missingNode = Node(id: 2)
        let knownBranch = Branch(id: 1)
        let missingBranch = Branch(id: 2)
        let state = SolutionState(
            variables: [1.25, -0.01],
            variableMap: [
                .nodeVoltage(knownNode): 0,
                .branchCurrent(knownBranch): 1
            ]
        )

        #expect(try state.checkedVoltage(at: knownNode) == 1.25)
        #expect(try state.checkedCurrent(through: knownBranch) == -0.01)
        #expect(throws: SolutionStateAccessError.missingNodeVoltage(nodeID: missingNode.id)) {
            _ = try state.checkedVoltage(at: missingNode)
        }
        #expect(throws: SolutionStateAccessError.missingBranchCurrent(branchID: missingBranch.id)) {
            _ = try state.checkedCurrent(through: missingBranch)
        }
    }

    @Test func mutualInductanceStampsACAndTransientBranchCoupling() throws {
        let positiveA = Node(id: 1)
        let positiveB = Node(id: 2)
        let branchA = Branch(id: 0)
        let branchB = Branch(id: 1)
        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(positiveA): 0,
            .nodeVoltage(positiveB): 1,
            .branchCurrent(branchA): 2,
            .branchCurrent(branchB): 3,
        ]
        var context = BindingContext(
            variableMap: variableMap,
            matrixDimension: 4,
            branchNames: [
                branchA: "L1",
                branchB: "L2",
            ]
        )

        let l1 = Instance(
            name: "L1",
            typeName: "inductor",
            nodes: [positiveA, .ground],
            parameters: ["l": .real(4.0e-6)]
        )
        let l2 = Instance(
            name: "L2",
            typeName: "inductor",
            nodes: [positiveB, .ground],
            parameters: ["l": .real(9.0e-6)]
        )
        _ = try InductorDescriptor().bind(instance: l1, context: &context)
        _ = try InductorDescriptor().bind(instance: l2, context: &context)

        let mutual = Instance(
            name: "K1",
            typeName: "mutual",
            nodes: [],
            parameters: [
                "k": .real(0.5),
                "inductor_a": .string("L1"),
                "inductor_b": .string("L2"),
            ]
        )
        let bound = try MutualInductanceDescriptor().bind(instance: mutual, context: &context)
        let expectedMutualInductance = 3.0e-6
        let state = SolutionState(
            variables: [0.0, 0.0, 0.0, 0.0],
            previousVariables: [0.0, 0.0, 0.1, 0.2],
            variableMap: variableMap
        )

        let complexCollector = ComplexStampCollector()
        var complexStamper = ComplexMatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, column, real, imag in
                complexCollector.addMatrix(row, column, real, imag)
            },
            stampRHS: { row, real, imag in
                complexCollector.addRHS(row, real, imag)
            }
        )

        bound.stampAC(into: &complexStamper, state: state, omega: 1_000.0)

        let acAB = complexCollector.matrixSum(row: 2, col: 3)
        let acBA = complexCollector.matrixSum(row: 3, col: 2)
        #expect(abs(acAB.real) < 1.0e-15)
        #expect(abs(acBA.real) < 1.0e-15)
        #expect(abs(acAB.imag + 1_000.0 * expectedMutualInductance) < 1.0e-15)
        #expect(abs(acBA.imag + 1_000.0 * expectedMutualInductance) < 1.0e-15)

        let collector = StampCollector()
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, column, value in collector.addMatrix(row, column, value) },
            stampRHS: { row, value in collector.addRHS(row, value) }
        )
        let integration = IntegrationState(method: .backwardEuler, timeStep: 1.0, currentTime: 1.0)

        bound.stampTransient(into: &stamper, state: state, integration: integration)

        #expect(abs(collector.matrixSum(row: 2, col: 3) + expectedMutualInductance) < 1.0e-15)
        #expect(abs(collector.matrixSum(row: 3, col: 2) + expectedMutualInductance) < 1.0e-15)
        #expect(abs(collector.rhsSum(row: 2) + expectedMutualInductance * 0.2) < 1.0e-15)
        #expect(abs(collector.rhsSum(row: 3) + expectedMutualInductance * 0.1) < 1.0e-15)
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

private extension ConvergenceResult {
    var isConverged: Bool {
        if case .converged = self {
            return true
        }
        return false
    }
}

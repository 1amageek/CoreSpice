import Testing
import Synchronization
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

private final class JFETStampCollector: Sendable {
    private let matrix = Mutex<[(Int, Int, Double)]>([])
    private let rhs = Mutex<[(Int, Double)]>([])

    func addMatrix(_ row: Int, _ column: Int, _ value: Double) {
        matrix.withLock { $0.append((row, column, value)) }
    }

    func addRHS(_ row: Int, _ value: Double) {
        rhs.withLock { $0.append((row, value)) }
    }

    func matrixSum(row: Int, column: Int) -> Double {
        matrix.withLock { entries in
            entries.filter { $0.0 == row && $0.1 == column }.map { $0.2 }.reduce(0, +)
        }
    }

    func rhsSum(row: Int) -> Double {
        rhs.withLock { entries in
            entries.filter { $0.0 == row }.map { $0.1 }.reduce(0, +)
        }
    }
}

@Suite("JFET device tests")
struct JFETTests {

    @Test("NJFET channel stamps transconductance and output conductance")
    func njfetChannelStampsSmallSignalTerms() throws {
        let drain = Node(id: 1)
        let gate = Node(id: 2)
        let source = Node(id: 3)
        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(drain): 0,
            .nodeVoltage(gate): 1,
            .nodeVoltage(source): 2
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let instance = Instance(
            name: "J1",
            typeName: "njfet",
            nodes: [drain, gate, source],
            parameters: [
                "beta": .real(1.0e-3),
                "vto": .real(-2.0),
                "lambda": .real(0.0),
            ]
        )
        let device = try NJFETDescriptor().bind(instance: instance, context: &context)
        let state = SolutionState(variables: [1.0, 0.0, 0.0], variableMap: variableMap)
        let collector = JFETStampCollector()
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, column, value in collector.addMatrix(row, column, value) },
            stampRHS: { row, value in collector.addRHS(row, value) }
        )

        device.stampDC(into: &stamper, state: state)

        #expect(collector.matrixSum(row: 0, column: 0) > 1.99e-3)
        #expect(collector.matrixSum(row: 0, column: 1) > 1.99e-3)
        #expect(collector.rhsSum(row: 0) < -9.9e-4)
    }

    @Test("PJFET uses opposite channel polarity")
    func pjfetUsesOppositeChannelPolarity() throws {
        let drain = Node(id: 1)
        let gate = Node(id: 2)
        let source = Node(id: 3)
        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(drain): 0,
            .nodeVoltage(gate): 1,
            .nodeVoltage(source): 2
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let instance = Instance(
            name: "J2",
            typeName: "pjfet",
            nodes: [drain, gate, source],
            parameters: [
                "beta": .real(1.0e-3),
                "vto": .real(-2.0),
                "lambda": .real(0.0),
            ]
        )
        let device = try PJFETDescriptor().bind(instance: instance, context: &context)
        let state = SolutionState(variables: [4.0, 5.0, 5.0], variableMap: variableMap)
        let collector = JFETStampCollector()
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, column, value in collector.addMatrix(row, column, value) },
            stampRHS: { row, value in collector.addRHS(row, value) }
        )

        device.stampDC(into: &stamper, state: state)

        #expect(collector.matrixSum(row: 0, column: 0) > 1.99e-3)
        #expect(collector.rhsSum(row: 0) > 9.9e-4)
    }

    @Test("PJFET default VTO follows SPICE depletion convention")
    func pjfetDefaultVTOConductsAtZeroGateBias() throws {
        let drain = Node(id: 1)
        let gate = Node(id: 2)
        let source = Node(id: 3)
        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(drain): 0,
            .nodeVoltage(gate): 1,
            .nodeVoltage(source): 2
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let instance = Instance(
            name: "Jdefault",
            typeName: "pjfet",
            nodes: [drain, gate, source],
            parameters: [
                "beta": .real(1.0e-3),
                "lambda": .real(0.0),
            ]
        )
        let device = try PJFETDescriptor().bind(instance: instance, context: &context)
        let state = SolutionState(variables: [4.0, 5.0, 5.0], variableMap: variableMap)
        let collector = JFETStampCollector()
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, column, value in collector.addMatrix(row, column, value) },
            stampRHS: { row, value in collector.addRHS(row, value) }
        )

        device.stampDC(into: &stamper, state: state)

        #expect(collector.matrixSum(row: 0, column: 0) > 1.99e-3)
        #expect(collector.rhsSum(row: 0) > 9.9e-4)
    }

    @Test("JFET area scales channel terms")
    func jfetAreaScalesChannelTerms() throws {
        let drain = Node(id: 1)
        let gate = Node(id: 2)
        let source = Node(id: 3)
        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(drain): 0,
            .nodeVoltage(gate): 1,
            .nodeVoltage(source): 2
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 3)
        let instance = Instance(
            name: "Jarea",
            typeName: "njfet",
            nodes: [drain, gate, source],
            parameters: [
                "beta": .real(1.0e-3),
                "vto": .real(-2.0),
                "area": .real(2.0),
            ]
        )
        let device = try NJFETDescriptor().bind(instance: instance, context: &context)
        let state = SolutionState(variables: [1.0, 0.0, 0.0], variableMap: variableMap)
        let collector = JFETStampCollector()
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, column, value in collector.addMatrix(row, column, value) },
            stampRHS: { row, value in collector.addRHS(row, value) }
        )

        device.stampDC(into: &stamper, state: state)

        #expect(collector.matrixSum(row: 0, column: 1) > 3.99e-3)
        #expect(collector.rhsSum(row: 0) < -1.99e-3)
    }

    @Test("JFET TNOM uses SPICE Celsius convention")
    func jfetTNOMUsesSpiceCelsiusConvention() throws {
        let gate = Node(id: 1)
        let variableMap: [MNAVariable: Int] = [.nodeVoltage(gate): 0]
        var context = BindingContext(variableMap: variableMap, matrixDimension: 1)
        let instance = Instance(
            name: "Jtnom",
            typeName: "njfet",
            nodes: [.ground, gate, .ground],
            parameters: [
                "is": .real(1.0e-12),
                "tnom": .real(27.0),
            ]
        )
        let device = try NJFETDescriptor().bind(instance: instance, context: &context)
        let state = SolutionState(variables: [0.7], variableMap: variableMap)
        let collector = JFETStampCollector()
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, column, value in collector.addMatrix(row, column, value) },
            stampRHS: { _, _ in }
        )

        device.stampDC(into: &stamper, state: state)

        #expect(collector.matrixSum(row: 0, column: 0) < 1000.0)
    }

    @Test("JFET rejects invalid physical parameters")
    func jfetRejectsInvalidPhysicalParameters() throws {
        let instance = Instance(
            name: "Jbad",
            typeName: "njfet",
            nodes: [Node(id: 1), Node(id: 2), .ground],
            parameters: ["beta": .real(0)]
        )
        var context = BindingContext(variableMap: [:], matrixDimension: 0)

        #expect(throws: DeviceBindingError.self) {
            _ = try NJFETDescriptor().bind(instance: instance, context: &context)
        }
    }
}

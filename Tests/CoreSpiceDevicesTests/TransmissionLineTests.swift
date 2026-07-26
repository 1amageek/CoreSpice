import Synchronization
import Testing
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

@Suite("Lossless transmission-line device")
struct TransmissionLineTests {
    @Test("Standard registry exposes the lossless line descriptor")
    func registryContainsDescriptor() {
        #expect(DeviceRegistry.standard().descriptor(for: "tline") != nil)
    }

    @Test("Descriptor validates impedance and delay alternatives")
    func validatesParameters() {
        let fixture = Fixture()
        var context = fixture.context()
        let invalid = fixture.instance(parameters: ["z0": .real(0), "td": .real(1e-9)])
        #expect(throws: DeviceBindingError.self) {
            _ = try TransmissionLineDescriptor().bind(instance: invalid, context: &context)
        }

        context = fixture.context()
        let conflicting = fixture.instance(
            parameters: ["z0": .real(50), "td": .real(1e-9), "f": .real(1e9)]
        )
        #expect(throws: DeviceBindingError.self) {
            _ = try TransmissionLineDescriptor().bind(instance: conflicting, context: &context)
        }
    }

    @Test("DC stamp enforces equal port voltages and opposite currents")
    func stampsDCLimit() throws {
        let fixture = Fixture()
        let device = try fixture.bind(parameters: ["z0": .real(50), "td": .real(1e-9)])
        let collector = RealCollector()
        var stamper = fixture.realStamper(collector: collector)

        device.stampDC(into: &stamper, state: fixture.zeroState())

        #expect(collector.matrix(row: 2, column: 0) == 1)
        #expect(collector.matrix(row: 2, column: 1) == -1)
        #expect(collector.matrix(row: 2, column: 2) == -50)
        #expect(collector.matrix(row: 2, column: 3) == -50)
        #expect(collector.matrix(row: 3, column: 1) == 1)
        #expect(collector.matrix(row: 3, column: 0) == -1)
    }

    @Test("AC stamp applies complex propagation to the remote port")
    func stampsACPropagation() throws {
        let fixture = Fixture()
        let delay = 1e-9
        let device = try fixture.bind(parameters: ["z0": .real(50), "td": .real(delay)])
        let collector = ComplexCollector()
        var stamper = fixture.complexStamper(collector: collector)

        device.stampAC(
            into: &stamper,
            state: fixture.zeroState(),
            omega: .pi / (2 * delay)
        )

        let remoteVoltage = collector.matrix(row: 2, column: 1)
        let remoteCurrent = collector.matrix(row: 2, column: 3)
        #expect(abs(remoteVoltage.real) < 1e-12)
        #expect(abs(remoteVoltage.imag - 1) < 1e-12)
        #expect(abs(remoteCurrent.real) < 1e-12)
        #expect(abs(remoteCurrent.imag - 50) < 1e-10)
    }

    @Test("Transient stamp interpolates accepted traveling-wave history")
    func interpolatesTransientHistory() throws {
        let fixture = Fixture()
        let bound = try fixture.bind(parameters: ["z0": .real(50), "td": .real(1)])
        let committing = try #require(bound as? any TransientStateCommittingDevice)
        let initial = SolutionState(
            variables: [10, 4, 0.1, -0.02],
            previousVariables: [10, 4, 0.1, -0.02],
            variableMap: fixture.variableMap
        )
        var initialStamper = fixture.realStamper(collector: RealCollector())
        bound.stampTransient(
            into: &initialStamper,
            state: initial,
            integration: IntegrationState(
                method: .backwardEuler,
                timeStep: 0.5,
                currentTime: 0.5
            )
        )

        let accepted = SolutionState(
            variables: [20, 8, 0.2, -0.04],
            previousVariables: initial.variables,
            variableMap: fixture.variableMap
        )
        committing.commitTransientStep(
            state: accepted,
            integration: IntegrationState(
                method: .backwardEuler,
                timeStep: 0.5,
                currentTime: 1
            )
        )

        let collector = RealCollector()
        var stamper = fixture.realStamper(collector: collector)
        bound.stampTransient(
            into: &stamper,
            state: accepted,
            integration: IntegrationState(
                method: .backwardEuler,
                timeStep: 0.5,
                currentTime: 1.5
            )
        )

        #expect(abs(collector.rhs(row: 2) - 4.5) < 1e-12)
        #expect(abs(collector.rhs(row: 3) - 22.5) < 1e-12)
    }

    @Test("History retention is bounded by the active delay window")
    func boundsHistoryRetention() {
        let history = TransmissionLineHistory()
        for index in 1...20_000 {
            history.commit(
                time: Double(index) * 0.01,
                waves: .init(fromPort1: Double(index), fromPort2: -Double(index)),
                delay: 1
            )
        }

        #expect(history.retainedSampleCount <= 102)
    }
}

private extension TransmissionLineTests {
    struct Fixture {
        let port1 = Node(id: 1)
        let port2 = Node(id: 2)
        let branch1 = Branch(id: 1)
        let branch2 = Branch(id: 2)

        var variableMap: [MNAVariable: Int] {
            [
                .nodeVoltage(port1): 0,
                .nodeVoltage(port2): 1,
                .branchCurrent(branch1): 2,
                .branchCurrent(branch2): 3,
            ]
        }

        func context() -> BindingContext {
            BindingContext(variableMap: variableMap, matrixDimension: 4)
        }

        func instance(parameters: [String: ParameterValue]) -> Instance {
            Instance(
                name: "T1",
                typeName: "tline",
                nodes: [port1, .ground, port2, .ground],
                parameters: parameters,
                ownedBranches: [branch1, branch2]
            )
        }

        func bind(parameters: [String: ParameterValue]) throws -> any BoundDevice {
            var bindingContext = context()
            return try TransmissionLineDescriptor().bind(
                instance: instance(parameters: parameters),
                context: &bindingContext
            )
        }

        func zeroState() -> SolutionState {
            SolutionState(variables: [0, 0, 0, 0], variableMap: variableMap)
        }

        func realStamper(collector: RealCollector) -> MatrixStamper {
            MatrixStamper(
                variableMap: variableMap,
                stampMatrix: { row, column, value in
                    collector.addMatrix(row: row, column: column, value: value)
                },
                stampRHS: { row, value in
                    collector.addRHS(row: row, value: value)
                }
            )
        }

        func complexStamper(collector: ComplexCollector) -> ComplexMatrixStamper {
            ComplexMatrixStamper(
                variableMap: variableMap,
                stampMatrix: { row, column, real, imaginary in
                    collector.addMatrix(
                        row: row,
                        column: column,
                        real: real,
                        imaginary: imaginary
                    )
                },
                stampRHS: { _, _, _ in }
            )
        }
    }

    final class RealCollector: Sendable {
        private struct State: Sendable {
            var matrix: [Entry] = []
            var rhs: [(Int, Double)] = []
        }

        private struct Entry: Sendable {
            let row: Int
            let column: Int
            let value: Double
        }

        private let state = Mutex(State())

        func addMatrix(row: Int, column: Int, value: Double) {
            state.withLock { $0.matrix.append(Entry(row: row, column: column, value: value)) }
        }

        func addRHS(row: Int, value: Double) {
            state.withLock { $0.rhs.append((row, value)) }
        }

        func matrix(row: Int, column: Int) -> Double {
            state.withLock { state in
                state.matrix
                    .filter { $0.row == row && $0.column == column }
                    .reduce(0) { $0 + $1.value }
            }
        }

        func rhs(row: Int) -> Double {
            state.withLock { state in
                state.rhs.filter { $0.0 == row }.reduce(0) { $0 + $1.1 }
            }
        }
    }

    final class ComplexCollector: Sendable {
        struct Value: Sendable {
            var real = 0.0
            var imag = 0.0
        }

        private struct Entry: Sendable {
            let row: Int
            let column: Int
            let value: Value
        }

        private let entries = Mutex<[Entry]>([])

        func addMatrix(
            row: Int,
            column: Int,
            real: Double,
            imaginary: Double
        ) {
            entries.withLock {
                $0.append(
                    Entry(
                        row: row,
                        column: column,
                        value: Value(real: real, imag: imaginary)
                    )
                )
            }
        }

        func matrix(row: Int, column: Int) -> Value {
            entries.withLock { entries in
                entries
                    .filter { $0.row == row && $0.column == column }
                    .reduce(into: Value()) {
                        $0.real += $1.value.real
                        $0.imag += $1.value.imag
                    }
            }
        }
    }
}

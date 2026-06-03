import Testing
import Synchronization
@testable import CoreSpiceDevices
@testable import CoreSpiceIR

private final class CapabilityStampCollector: Sendable {
    private let matrix = Mutex<[(Int, Int, Double)]>([])
    private let rhs = Mutex<[(Int, Double)]>([])

    func addMatrix(_ row: Int, _ col: Int, _ value: Double) {
        matrix.withLock { $0.append((row, col, value)) }
    }

    func addRHS(_ row: Int, _ value: Double) {
        rhs.withLock { $0.append((row, value)) }
    }

    func rhsSum(row: Int) -> Double {
        rhs.withLock { values in
            values.filter { $0.0 == row }.map { $0.1 }.reduce(0, +)
        }
    }

    func reset() {
        matrix.withLock { $0.removeAll() }
        rhs.withLock { $0.removeAll() }
    }
}

@Suite("Transient and noise capability contracts")
struct TransientAndNoiseCapabilityTests {

    @Test("Transient capacitance store uses committed trapezoidal history")
    func transientCapacitanceStoreUsesCommittedTrapezoidalHistory() {
        let positive = Node(id: 1)
        let negative = Node(id: 2)
        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(positive): 0,
            .nodeVoltage(negative): 1
        ]
        let integration = IntegrationState(
            method: .trapezoidal,
            timeStep: 1.0,
            currentTime: 1.0
        )
        let store = TransientCapacitanceStore()
        let collector = CapabilityStampCollector()
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { row, column, value in collector.addMatrix(row, column, value) },
            stampRHS: { row, value in collector.addRHS(row, value) }
        )

        let firstState = SolutionState(
            variables: [1.0, 0.0],
            previousVariables: [0.0, 0.0],
            variableMap: variableMap
        )
        store.stamp(
            key: "c",
            into: &stamper,
            node1: 0,
            node2: 1,
            capacitance: 1.0,
            state: firstState,
            integration: integration
        )
        #expect(collector.rhsSum(row: 0) == 0.0)

        store.commit(
            key: "c",
            node1: 0,
            node2: 1,
            capacitance: 1.0,
            state: firstState,
            integration: integration
        )

        collector.reset()
        let secondState = SolutionState(
            variables: [1.0, 0.0],
            previousVariables: [1.0, 0.0],
            variableMap: variableMap
        )
        store.stamp(
            key: "c",
            into: &stamper,
            node1: 0,
            node2: 1,
            capacitance: 1.0,
            state: secondState,
            integration: integration
        )

        #expect(collector.rhsSum(row: 0) == 4.0)
        #expect(collector.rhsSum(row: 1) == -4.0)
    }

    @Test("MOSFET capacitance history follows physical terminals across reversal")
    func mosfetCapacitanceHistoryFollowsPhysicalTerminalsAcrossReversal() throws {
        let drain = Node(id: 1)
        let gate = Node(id: 2)
        let variableMap: [MNAVariable: Int] = [
            .nodeVoltage(drain): 0,
            .nodeVoltage(gate): 1
        ]
        var context = BindingContext(variableMap: variableMap, matrixDimension: variableMap.count)
        let instance = Instance(
            name: "MREV",
            typeName: "nmos_l1",
            nodes: [drain, gate, .ground, .ground],
            parameters: [
                "vto": .real(10.0),
                "kp": .real(0.0),
                "w": .real(1.0),
                "l": .real(1.0),
                "cgso": .real(1.0),
                "cgdo": .real(3.0)
            ]
        )
        let registry = DeviceRegistry.standard()
        let descriptor = try #require(registry.descriptor(for: "nmos_l1"))
        let device = try descriptor.bind(instance: instance, context: &context)
        let committingDevice = try #require(device as? any TransientStateCommittingDevice)
        let integration = IntegrationState(method: .trapezoidal, timeStep: 1.0, currentTime: 1.0)

        let forwardState = SolutionState(
            variables: [1.0, 4.0],
            previousVariables: [0.0, 0.0],
            variableMap: variableMap
        )
        committingDevice.commitTransientStep(state: forwardState, integration: integration)

        let collector = CapabilityStampCollector()
        var stamper = MatrixStamper(
            variableMap: variableMap,
            stampMatrix: { _, _, _ in },
            stampRHS: { row, value in collector.addRHS(row, value) }
        )
        let reversedState = SolutionState(
            variables: [-1.0, 4.0],
            previousVariables: [1.0, 4.0],
            variableMap: variableMap
        )
        device.stampTransient(into: &stamper, state: reversedState, integration: integration)

        #expect(collector.rhsSum(row: 0) < -20.0)
    }

    @Test("Built-in dynamic devices expose transient commit capability")
    func builtInDynamicDevicesExposeTransientCommitCapability() throws {
        let specs: [(String, [Node], [String: ParameterValue])] = [
            ("capacitor", [Node(id: 1), .ground], ["c": .real(1e-12)]),
            ("diode", [Node(id: 1), .ground], ["cjo": .real(1e-12), "tt": .real(1e-9)]),
            ("npn", [Node(id: 1), Node(id: 2), .ground], ["cje": .real(1e-12), "cjc": .real(1e-12), "tf": .real(1e-9)]),
            ("pnp", [Node(id: 1), Node(id: 2), Node(id: 3)], ["cje": .real(1e-12), "cjc": .real(1e-12), "tf": .real(1e-9)]),
            ("nmos_l1", [Node(id: 1), Node(id: 2), .ground, .ground], mosCapacitanceParameters()),
            ("pmos_l1", [Node(id: 1), Node(id: 2), Node(id: 3), Node(id: 3)], mosCapacitanceParameters()),
            ("nmos_l2", [Node(id: 1), Node(id: 2), .ground, .ground], mosCapacitanceParameters()),
            ("pmos_l2", [Node(id: 1), Node(id: 2), Node(id: 3), Node(id: 3)], mosCapacitanceParameters()),
            ("nmos_l3", [Node(id: 1), Node(id: 2), .ground, .ground], mosCapacitanceParameters()),
            ("pmos_l3", [Node(id: 1), Node(id: 2), Node(id: 3), Node(id: 3)], mosCapacitanceParameters())
        ]

        for (typeName, nodes, parameters) in specs {
            let device = try bindDevice(typeName: typeName, nodes: nodes, parameters: parameters)
            #expect(device is any TransientStateCommittingDevice, "\(typeName) must commit transient history")
        }
    }

    @Test("Semiconductor junction devices expose shot noise sources")
    func semiconductorJunctionDevicesExposeShotNoiseSources() throws {
        let diode = try bindDevice(
            typeName: "diode",
            nodes: [Node(id: 1), .ground],
            parameters: ["is": .real(1e-12)]
        )
        let diodeState = SolutionState(
            variables: [0.7],
            variableMap: [.nodeVoltage(Node(id: 1)): 0]
        )
        let diodeNoise = (diode as? any NoisyDevice)?.noiseContributions(
            state: diodeState,
            frequency: 1_000
        )
        #expect(diodeNoise?.first?.currentSpectralDensity ?? 0 > 0)

        let npn = try bindDevice(
            typeName: "npn",
            nodes: [Node(id: 1), Node(id: 2), .ground],
            parameters: ["is": .real(1e-15), "bf": .real(100)]
        )
        let npnState = SolutionState(
            variables: [5.0, 0.7],
            variableMap: [.nodeVoltage(Node(id: 1)): 0, .nodeVoltage(Node(id: 2)): 1]
        )
        let npnNoise = (npn as? any NoisyDevice)?.noiseContributions(
            state: npnState,
            frequency: 1_000
        )
        #expect(npnNoise?.contains { $0.currentSpectralDensity > 0 } == true)

        let pnp = try bindDevice(
            typeName: "pnp",
            nodes: [Node(id: 1), Node(id: 2), Node(id: 3)],
            parameters: ["is": .real(1e-15), "bf": .real(100)]
        )
        let pnpState = SolutionState(
            variables: [0.0, 4.3, 5.0],
            variableMap: [
                .nodeVoltage(Node(id: 1)): 0,
                .nodeVoltage(Node(id: 2)): 1,
                .nodeVoltage(Node(id: 3)): 2
            ]
        )
        let pnpNoise = (pnp as? any NoisyDevice)?.noiseContributions(
            state: pnpState,
            frequency: 1_000
        )
        #expect(pnpNoise?.contains { $0.currentSpectralDensity > 0 } == true)
    }

    @Test("MOSFET devices expose channel thermal noise sources")
    func mosfetDevicesExposeChannelThermalNoiseSources() throws {
        let nmosState = SolutionState(
            variables: [1.0, 2.0],
            variableMap: [
                .nodeVoltage(Node(id: 1)): 0,
                .nodeVoltage(Node(id: 2)): 1
            ]
        )
        let pmosState = SolutionState(
            variables: [0.0, 0.0, 5.0],
            variableMap: [
                .nodeVoltage(Node(id: 1)): 0,
                .nodeVoltage(Node(id: 2)): 1,
                .nodeVoltage(Node(id: 3)): 2
            ]
        )

        let specs: [(String, [Node], [String: ParameterValue], SolutionState)] = [
            ("nmos_l1", [Node(id: 1), Node(id: 2), .ground, .ground], nmosNoiseParameters(), nmosState),
            ("nmos_l2", [Node(id: 1), Node(id: 2), .ground, .ground], nmosNoiseParameters(), nmosState),
            ("nmos_l3", [Node(id: 1), Node(id: 2), .ground, .ground], nmosNoiseParameters(), nmosState),
            ("pmos_l1", [Node(id: 1), Node(id: 2), Node(id: 3), Node(id: 3)], pmosNoiseParameters(), pmosState),
            ("pmos_l2", [Node(id: 1), Node(id: 2), Node(id: 3), Node(id: 3)], pmosNoiseParameters(), pmosState),
            ("pmos_l3", [Node(id: 1), Node(id: 2), Node(id: 3), Node(id: 3)], pmosNoiseParameters(), pmosState)
        ]

        for (typeName, nodes, parameters, state) in specs {
            let device = try bindDevice(typeName: typeName, nodes: nodes, parameters: parameters)
            let noisyDevice = try #require(device as? any NoisyDevice, "\(typeName) must expose MOSFET channel noise")
            let contributions = noisyDevice.noiseContributions(state: state, frequency: 1_000)
            #expect(contributions.contains { $0.name == "\(typeName.uppercased())_channel_thermal" })
            #expect(contributions.contains { $0.currentSpectralDensity > 0 })
        }
    }

    private func bindDevice(
        typeName: String,
        nodes: [Node],
        parameters: [String: ParameterValue]
    ) throws -> any BoundDevice {
        let variableMap = variableMap(for: nodes)
        var context = BindingContext(
            variableMap: variableMap,
            matrixDimension: variableMap.count
        )
        let instance = Instance(
            name: typeName.uppercased(),
            typeName: typeName,
            nodes: nodes,
            parameters: parameters
        )
        let registry = DeviceRegistry.standard()
        guard let descriptor = registry.descriptor(for: typeName) else {
            throw CapabilityContractError.missingDescriptor(typeName)
        }
        return try descriptor.bind(instance: instance, context: &context)
    }

    private func variableMap(for nodes: [Node]) -> [MNAVariable: Int] {
        var nextIndex = 0
        var map: [MNAVariable: Int] = [:]
        for node in nodes where node != .ground {
            let variable = MNAVariable.nodeVoltage(node)
            if map[variable] == nil {
                map[variable] = nextIndex
                nextIndex += 1
            }
        }
        return map
    }

    private func mosCapacitanceParameters() -> [String: ParameterValue] {
        [
            "tox": .real(2e-9),
            "cgso": .real(1e-10),
            "cgdo": .real(1e-10),
            "cgbo": .real(1e-10),
            "cj": .real(1e-3),
            "cjsw": .real(1e-10),
            "ad": .real(1e-12),
            "as": .real(1e-12),
            "pd": .real(4e-6),
            "ps": .real(4e-6)
        ]
    }

    private func nmosNoiseParameters() -> [String: ParameterValue] {
        [
            "vto": .real(0.7),
            "kp": .real(2e-5),
            "w": .real(10e-6),
            "l": .real(1e-6)
        ]
    }

    private func pmosNoiseParameters() -> [String: ParameterValue] {
        [
            "vto": .real(-0.7),
            "kp": .real(2e-5),
            "w": .real(10e-6),
            "l": .real(1e-6)
        ]
    }
}

private enum CapabilityContractError: Error {
    case missingDescriptor(String)
}

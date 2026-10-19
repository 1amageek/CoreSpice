import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceMOSContracts
import Foundation
import Synchronization
import Testing

private final class L3Stamps: Sendable {
    struct Values: Sendable {
        var real = [Double](repeating: 0, count: 16)
        var imag = [Double](repeating: 0, count: 16)
        var rhs = [Double](repeating: 0, count: 4)
    }
    private let storage = Mutex(Values())
    func matrix(_ row: Int, _ column: Int, _ real: Double, _ imag: Double = 0) {
        storage.withLock {
            $0.real[row * 4 + column] += real
            $0.imag[row * 4 + column] += imag
        }
    }
    func rhs(_ row: Int, _ value: Double) { storage.withLock { $0.rhs[row] += value } }
    var values: Values { storage.withLock { $0 } }
}

@Suite("Level 3 current and linearization contracts", .timeLimit(.minutes(1)))
struct MOSL3ConsistencyTests {
    private let nodes = (1...4).map { Node(id: $0) }
    private var variableMap: [MNAVariable: Int] {
        Dictionary(uniqueKeysWithValues: nodes.enumerated().map { (.nodeVoltage($0.element), $0.offset) })
    }
    private struct Parameters {
        var model: [String: Double]
        var instance: [String: Double]
    }
    private func parameters(polarity: Double) -> Parameters {
        Parameters(model: ["vto": polarity * 0.7, "kp": 2e-4, "gamma": 0.5,
            "phi": 0.6, "theta": 0.2, "eta": 0.03, "kappa": 0.3],
            instance: ["w": 10e-6, "l": 1e-6])
    }
    private func bind(polarity: Double, parameters: Parameters? = nil) throws -> any BoundDevice {
        let values = parameters ?? self.parameters(polarity: polarity)
        return try PreparedMOSFixture.bind(typeName: polarity == 1 ? "nmos_l3" : "pmos_l3",
            nodes: nodes, model: values.model, instance: values.instance, variableMap: variableMap)
    }
    private func dc(_ device: any BoundDevice, _ voltage: [Double], csr: Bool = false) throws -> L3Stamps.Values {
        let collector = L3Stamps()
        var stamper = MatrixStamper(variableMap: variableMap,
                                   stampMatrix: { collector.matrix($0, $1, $2) },
                                   stampRHS: { collector.rhs($0, $1) },
                                   stampValue: csr ? { collector.matrix($0 / 4, $0 % 4, $1) } : nil)
        try device.stampDC(into: &stamper, state: SolutionState(variables: voltage, variableMap: variableMap))
        return collector.values
    }
    private func currents(_ stamp: L3Stamps.Values, _ voltage: [Double]) -> [Double] {
        (0..<4).map { row in
            (0..<4).reduce(-stamp.rhs[row]) { $0 + stamp.real[row * 4 + $1] * voltage[$1] }
        }
    }
    private func close(_ actual: Double, _ expected: Double, absolute: Double = 2e-11) {
        #expect(abs(actual - expected) <= absolute + abs(expected) * 2e-5)
    }

    @Test("Physical terminal Jacobian agrees with finite differences in every region")
    func terminalJacobianMatchesFiniteDifferences() throws {
        let biases: [[Double]] = [
            [0.2, -2, 0, -0.4], [0.2, 2, 0, -0.4], [2, 2, 0, -0.4],
            [-0.2, 2, 0, -0.6], [-2, 0, 0, -2.4], [0.2, 2, 0, 0.8]
        ]
        for polarity in [1.0, -1.0] {
            let device = try bind(polarity: polarity)
            for canonical in biases {
                let voltage = canonical.map { polarity * $0 }
                let stamp = try dc(device, voltage)
                let current = currents(stamp, voltage)
                close(current.reduce(0, +), 0)
                close(current[1], 0)
                close(current[3], 0)
                for column in 0..<4 {
                    var plus = voltage
                    var minus = voltage
                    plus[column] += 1e-6
                    minus[column] -= 1e-6
                    let ip = currents(try dc(device, plus), plus)
                    let im = currents(try dc(device, minus), minus)
                    for row in 0..<4 {
                        close(stamp.real[row * 4 + column], (ip[row] - im[row]) / 2e-6)
                    }
                }
            }
        }
    }

    @Test("PMOS current is the polarity transform of NMOS including body and reversal")
    func polarityAndReverseCurrentAgree() throws {
        let n = try bind(polarity: 1)
        let p = try bind(polarity: -1)
        for v in [[0.2, 2.0, 0, -0.4], [2, 2, 0, -0.4], [-1, 1, 0, -1.4]] {
            let iv = currents(try dc(n, v), v)
            let pv = v.map { -$0 }
            let ip = currents(try dc(p, pv), pv)
            for row in 0..<4 { close(iv[row], -ip[row]) }
            let reversed = [v[2], v[1], v[0], v[3]]
            let ir = currents(try dc(n, reversed), reversed)
            close(iv[0], ir[2])
        }
    }

    @Test("Channel regularization contributes the same leakage current and derivative")
    func regularizationCurrentMatchesDerivative() throws {
        for polarity in [1.0, -1.0] {
            let device = try bind(polarity: polarity, parameters: Parameters(model: ["kp": 0], instance: [:]))
            let v = [0.2, 0.0, 0, 0].map { polarity * $0 }
            let stamp = try dc(device, v)
            close(currents(stamp, v)[0], polarity * 2e-13, absolute: 1e-25)
            close(stamp.real[0], 1e-12, absolute: 1e-25)
        }
    }

    @Test("Level 3 rejects invalid mobility and velocity denominators with typed errors")
    func invalidDenominatorsFailBinding() throws {
        for polarity in [1.0, -1.0] {
            for parameter in ["theta", "kappa"] {
                var p = parameters(polarity: polarity)
                p.model[parameter] = -1
                do {
                    _ = try bind(polarity: polarity, parameters: p)
                    Issue.record("Invalid denominator parameter was admitted")
                } catch MOSPreparationFailure.kernelRejected(let message) {
                    #expect(message.contains("M1"))
                    #expect(message.contains(parameter))
                }
            }
            let invalidDerived: [(String, [String: Double])] = [
                ("beta", ["kp": 1e308]),
                ("cox", ["tox": 1e-320]),
                ("velocityCoefficient", ["tox": 10e-9, "vmax": 1e-320]),
                ("effectiveVelocityCoefficient", ["tox": 10e-9, "vmax": 1e-303,
                                                  "kappa": Double.greatestFiniteMagnitude])
            ]
            for (expected, overrides) in invalidDerived {
                var p = parameters(polarity: polarity)
                p.model.merge(overrides) { _, replacement in replacement }
                do {
                    _ = try bind(polarity: polarity, parameters: p)
                    Issue.record("Non-finite derived coefficient was admitted")
                } catch MOSPreparationFailure.kernelRejected(let message) {
                    #expect(message.contains("M1"))
                    #expect(message.contains(expected))
                }
            }
        }
    }

    @Test("Coordinate and CSR stamps share the AC real Jacobian and conservative capacitances")
    func csrAndACShareChannelJacobian() throws {
        for polarity in [1.0, -1.0] {
            var p = parameters(polarity: polarity)
            p.model["tox"] = 10e-9
            p.model["vmax"] = 1e5
            p.model["cgso"] = 1e-10
            p.model["cgdo"] = 3e-10
            p.model["cj"] = 1e-3
            p.instance["ad"] = 2e-12
            p.instance["as"] = 1e-12
            let device = try bind(polarity: polarity, parameters: p)
            for canonical in [[0.2, 2.0, 0, -0.4], [2, 2, 0, -0.4], [-1, 1, 0, -1.4]] {
                let voltage = canonical.map { polarity * $0 }
                let coordinate = try dc(device, voltage)
                let csr = try dc(device, voltage, csr: true)
                let collector = L3Stamps()
                var stamper = ComplexMatrixStamper(variableMap: variableMap,
                    stampMatrix: { collector.matrix($0, $1, $2, $3) }, stampRHS: { _, _, _ in })
                try device.stampAC(into: &stamper,
                    state: SolutionState(variables: voltage, variableMap: variableMap), omega: 1e6)
                let ac = collector.values
                for i in 0..<16 {
                    close(csr.real[i], coordinate.real[i])
                    close(ac.real[i], coordinate.real[i])
                    #expect(ac.imag[i].isFinite)
                }
                for row in 0..<4 {
                    close(csr.rhs[row], coordinate.rhs[row])
                    close((0..<4).reduce(0.0) { $0 + ac.imag[row * 4 + $1] }, 0, absolute: 1e-18)
                    #expect(ac.imag[row * 4 + row] >= 0)
                }
                #expect(ac.imag[5] > 0)
            }
        }
    }

    @Test("Reverse-channel capacitance retains physical overlaps and diffusion areas")
    func reversedCapacitanceRetainsPhysicalGeometry() throws {
        for polarity in [1.0, -1.0] {
            let p = Parameters(model: ["kp": 0, "cgso": 1e-12, "cgdo": 3e-12, "cj": 1e-3],
                instance: ["w": 1, "l": 1, "ad": 2e-12, "as": 1e-12])
            let device = try bind(polarity: polarity, parameters: p)
            for drainBias in [-1.0, 1.0] {
                let voltage = [drainBias, 0, 0, -2].map { polarity * $0 }
                let collector = L3Stamps()
                var stamper = ComplexMatrixStamper(variableMap: variableMap,
                    stampMatrix: { collector.matrix($0, $1, $2, $3) }, stampRHS: { _, _, _ in })
                try device.stampAC(into: &stamper,
                    state: SolutionState(variables: voltage, variableMap: variableMap), omega: 1)
                let stamp = collector.values
                close(stamp.imag[4], -3e-12, absolute: 1e-25)
                close(stamp.imag[6], -1e-12, absolute: 1e-25)
                close(stamp.imag[3], -2e-15 / sqrt(1 + (2 + drainBias) / 0.8), absolute: 1e-25)
                close(stamp.imag[11], -1e-15 / sqrt(1 + 2 / 0.8), absolute: 1e-25)
            }
        }
    }

    @Test("L3 transient companions use accepted physical-terminal history")
    func transientUsesAcceptedHistory() throws {
        for polarity in [1.0, -1.0] {
            let device = try bind(polarity: polarity, parameters: Parameters(model: ["kp": 0, "cgso": 1e-12, "cgdo": 3e-12],
                instance: ["w": 1, "l": 1]))
            let integration = IntegrationState(method: .trapezoidal, timeStep: 1, currentTime: 1)
            let first = [1.0, 4, 0, 0].map { polarity * $0 }
            let accepted = SolutionState(variables: first, previousVariables: [0, 0, 0, 0],
                                         variableMap: variableMap)
            let committing = try #require(device as? any TransientStateCommittingDevice)
            try committing.commitTransientStep(state: accepted, integration: integration)
            let next = [-1.0, 4, 0, 0].map { polarity * $0 }
            let collector = L3Stamps()
            var stamper = MatrixStamper(variableMap: variableMap,
                stampMatrix: { collector.matrix($0, $1, $2) }, stampRHS: { collector.rhs($0, $1) })
            try device.stampTransient(into: &stamper,
                state: SolutionState(variables: next, previousVariables: first, variableMap: variableMap),
                integration: integration)
            let stamp = collector.values
            let channel = try dc(device, next)
            close(stamp.real[5] - channel.real[5], 8e-12, absolute: 1e-25)
            close(stamp.rhs[1] - channel.rhs[1], polarity * 52e-12, absolute: 1e-25)
            close(stamp.rhs[0] - channel.rhs[0], -polarity * 36e-12, absolute: 1e-25)
            close(stamp.rhs[2] - channel.rhs[2], -polarity * 16e-12, absolute: 1e-25)
        }
    }

    private func prepared(polarity: Double, overrides: [String: Double] = [:]) throws -> (PreparedCircuit, [Double], [Branch]) {
        var netlist = Netlist()
        let voltage = [2.0, 2, 0, -0.4].map { polarity * $0 }
        var branches: [Branch] = []
        for index in 0..<4 {
            _ = netlist.node("n\(index)")
            let name = "V\(index)"
            let branch = netlist.branch(name: name)
            branches.append(branch)
            try netlist.addInstance(name: name, typeName: "vsource", nodes: ["n\(index)", "0"],
                parameters: ["v": .real(voltage[index]), "ac": .real(index == 1 ? polarity : 0)],
                ownedBranches: [branch])
        }
        var model: [String: Double] = [
            "vto": polarity * 0.7, "kp": 2e-4, "gamma": 0.5, "phi": 0.6,
            "theta": 0.2, "eta": 0.03, "kappa": 0.3, "cgso": 1e-10
        ]
        model.merge(overrides) { _, replacement in replacement }
        let owner = try PreparedMOSFixture.prepare(.level3, polarity: polarity == 1 ? .nmos : .pmos,
            model: model, instance: ["w": 10e-6, "l": 1e-6])
        try netlist.addInstance(name: "M1", typeName: polarity == 1 ? "nmos_l3" : "pmos_l3",
            nodes: ["n0", "n1", "n2", "n3"], mos: .prepared(owner.receipt),
            ownedNodeCount: owner.receipt.topology.auxiliaryNodeCount)
        let ir = try netlist.build()
        let plan = try StandardCompiler().compile(ir: ir)
        let structure = plan.matrixStructure
        var context = BindingContext(variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension,
            stampIndexResolver: { structure.index(row: $0, col: $1) })
        var devices: [any BoundDevice] = []
        for instance in ir.instances.dropLast() {
            let descriptor = try #require(DeviceRegistry.standard().descriptor(for: instance.typeName))
            devices.append(try descriptor.bind(instance: instance, context: &context))
        }
        let mos = try #require(ir.instances.last)
        devices.append(try owner.bind(instance: mos, context: &context))
        return (try PreparedCircuit(plan: plan, devices: devices), voltage, branches)
    }

    @Test("Production DC AC and transient analyses execute both L3 polarities")
    func productionAnalysesMatchChannel() async throws {
        for polarity in [1.0, -1.0] {
            let (circuit, voltage, branches) = try prepared(polarity: polarity)
            let dcResult = try await DCAnalysis().run(circuit: circuit, solver: SparseLUSolver(),
                observer: nil, cancellation: CancellationToken())
            let device = try #require(circuit.devices.last)
            var p = parameters(polarity: polarity)
            p.model["cgso"] = 1e-10
            let local = try bind(polarity: polarity, parameters: p)
            let stamp = try dc(local, voltage)
            let current = currents(stamp, voltage)
            for row in 0..<4 {
                let nodeIndex = try #require(circuit.plan.topology.variableMap[.nodeVoltage(device.instance.nodes[row])])
                let branchIndex = try #require(circuit.plan.topology.variableMap[.branchCurrent(branches[row])])
                close(dcResult.variables[nodeIndex], voltage[row])
                close(dcResult.variables[branchIndex], -current[row])
            }
            let ac = try await ACAnalysis(sweep: .linear(start: 1e3, stop: 1e3, points: 1))
                .run(circuit: circuit, solver: SparseLUSolver(), observer: nil,
                     cancellation: CancellationToken())
            let drainBranch = try #require(circuit.plan.topology.variableMap[.branchCurrent(branches[0])])
            close(ac.solutions[0][drainBranch].real, -polarity * stamp.real[1])
            let config = TransientConfig(stopTime: 3e-9, executionLimits: .validationFixture, maxTimeStep: 1e-9, initialTimeStep: 1e-9)
            let transient = try await TransientAnalysis(config: config).run(circuit: circuit,
                solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            #expect(transient.timeSteps >= 3)
            #expect(transient.timePoints.last == config.stopTime)
            for point in transient.timePoints.indices {
                close(try transient.value(variableIndex: drainBranch, timeIndex: point), -current[0])
            }
        }
    }

    @Test("Extreme finite model arithmetic fails the production DC analysis explicitly")
    func nonFiniteChannelFailsAnalysis() async throws {
        let (circuit, _, _) = try prepared(polarity: 1, overrides: [
            "theta": 0, "kappa": 0, "eta": 0
        ])
        let nodes = try #require(circuit.devices.last).instance.nodes
        let analysis = DCAnalysis(nodeInitialGuess: [nodes[0]: 1e200, nodes[1]: 1e200])
        let variableMap = circuit.plan.topology.variableMap
        var initial = [Double](repeating: 0, count: circuit.plan.topology.dimension)
        for node in nodes.prefix(2) {
            initial[try #require(variableMap[.nodeVoltage(node)])] = 1e200
        }
        let state = SolutionState(variables: initial, variableMap: variableMap)
        var stamped = SparseMatrix(structure: circuit.plan.matrixStructure)
        var stamper = MatrixStamper(variableMap: variableMap,
            stampMatrix: { stamped.addValue(row: $0, col: $1, value: $2) },
            stampRHS: { _, _ in },
            stampValue: { stamped.addValueDirect(at: $0, value: $1) })
        for device in circuit.devices { try device.stampDC(into: &stamper, state: state) }
        #expect(stamped.values.contains { !$0.isFinite })
        do {
            _ = try await analysis.run(circuit: circuit, solver: SparseLUSolver(), observer: nil,
                                       cancellation: CancellationToken())
            Issue.record("Overflowing L3 channel produced successful DC evidence")
        } catch SparseSolverError.nonFiniteMatrixValue(let index) {
            // Sparse LU rejects the original nonfinite coefficient before an update or residual exists.
            #expect(stamped.values.indices.contains(index))
            if stamped.values.indices.contains(index) { #expect(!stamped.values[index].isFinite) }
        } catch let error as AnalysisError {
            switch error {
            case .nonFiniteSolution, .nonFiniteResidual: break
            default: Issue.record("Expected a numerical-failure diagnostic, got \(error)")
            }
        }
    }
}

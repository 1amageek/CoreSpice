import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
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
    private func parameters(polarity: Double) -> [String: ParameterValue] {
        ["vto": .real(polarity * 0.7), "kp": .real(2e-4), "gamma": .real(0.5),
         "phi": .real(0.6), "w": .real(10e-6), "l": .real(1e-6),
         "theta": .real(0.2), "eta": .real(0.03), "kappa": .real(0.3)]
    }
    private func bind(polarity: Double, parameters: [String: ParameterValue]? = nil,
                      csr: Bool = false) throws -> any BoundDevice {
        let type = polarity == 1 ? "nmos_l3" : "pmos_l3"
        let descriptor = try #require(DeviceRegistry.standard().descriptor(for: type))
        let fullResolver: @Sendable (Int, Int) -> Int? = { row, column in row * 4 + column }
        let resolver = csr ? fullResolver : nil
        var context = BindingContext(variableMap: variableMap, matrixDimension: 4,
                                     stampIndexResolver: resolver)
        return try descriptor.bind(instance: Instance(name: "M1", typeName: type, nodes: nodes,
                                                      parameters: parameters ?? self.parameters(polarity: polarity)),
                                   context: &context)
    }
    private func dc(_ device: any BoundDevice, _ voltage: [Double], csr: Bool = false) -> L3Stamps.Values {
        let collector = L3Stamps()
        var stamper = MatrixStamper(variableMap: variableMap,
                                   stampMatrix: { collector.matrix($0, $1, $2) },
                                   stampRHS: { collector.rhs($0, $1) },
                                   stampValue: csr ? { collector.matrix($0 / 4, $0 % 4, $1) } : nil)
        device.stampDC(into: &stamper, state: SolutionState(variables: voltage, variableMap: variableMap))
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
                let stamp = dc(device, voltage)
                let current = currents(stamp, voltage)
                close(current.reduce(0, +), 0)
                close(current[1], 0)
                close(current[3], 0)
                for column in 0..<4 {
                    var plus = voltage
                    var minus = voltage
                    plus[column] += 1e-6
                    minus[column] -= 1e-6
                    let ip = currents(dc(device, plus), plus)
                    let im = currents(dc(device, minus), minus)
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
            let iv = currents(dc(n, v), v)
            let pv = v.map { -$0 }
            let ip = currents(dc(p, pv), pv)
            for row in 0..<4 { close(iv[row], -ip[row]) }
            let reversed = [v[2], v[1], v[0], v[3]]
            let ir = currents(dc(n, reversed), reversed)
            close(iv[0], ir[2])
        }
    }

    @Test("Channel regularization contributes the same leakage current and derivative")
    func regularizationCurrentMatchesDerivative() throws {
        for polarity in [1.0, -1.0] {
            let device = try bind(polarity: polarity, parameters: ["kp": .real(0)])
            let v = [0.2, 0.0, 0, 0].map { polarity * $0 }
            let stamp = dc(device, v)
            close(currents(stamp, v)[0], polarity * 2e-13, absolute: 1e-25)
            close(stamp.real[0], 1e-12, absolute: 1e-25)
        }
    }

    @Test("Level 3 rejects invalid mobility and velocity denominators with typed errors")
    func invalidDenominatorsFailBinding() throws {
        for polarity in [1.0, -1.0] {
            for parameter in ["theta", "kappa"] {
                var p = parameters(polarity: polarity)
                p[parameter] = .real(-1)
                do {
                    _ = try bind(polarity: polarity, parameters: p)
                    Issue.record("Invalid denominator parameter was admitted")
                } catch DeviceBindingError.invalidParameterValue(let device, let name, _) {
                    #expect(device == "M1")
                    #expect(name == parameter)
                }
            }
            let invalidDerived: [(String, [String: ParameterValue])] = [
                ("beta", ["kp": .real(1e308)]),
                ("cox", ["tox": .real(1e-320)]),
                ("velocityCoefficient", ["tox": .real(10e-9), "vmax": .real(1e-320)]),
                ("effectiveVelocityCoefficient", ["tox": .real(10e-9), "vmax": .real(1e-303),
                                                  "kappa": .real(Double.greatestFiniteMagnitude)])
            ]
            for (expected, overrides) in invalidDerived {
                var p = parameters(polarity: polarity)
                p.merge(overrides) { _, replacement in replacement }
                do {
                    _ = try bind(polarity: polarity, parameters: p)
                    Issue.record("Non-finite derived coefficient was admitted")
                } catch DeviceBindingError.invalidParameterValue(let device, let name, _) {
                    #expect(device == "M1")
                    #expect(name == expected)
                }
            }
        }
    }

    @Test("Coordinate and CSR stamps share the AC real Jacobian and conservative capacitances")
    func csrAndACShareChannelJacobian() throws {
        for polarity in [1.0, -1.0] {
            var p = parameters(polarity: polarity)
            p["tox"] = .real(10e-9)
            p["vmax"] = .real(1e5)
            p["cgso"] = .real(1e-10)
            p["cgdo"] = .real(3e-10)
            p["cj"] = .real(1e-3)
            p["ad"] = .real(2e-12)
            p["as"] = .real(1e-12)
            let device = try bind(polarity: polarity, parameters: p, csr: true)
            for canonical in [[0.2, 2.0, 0, -0.4], [2, 2, 0, -0.4], [-1, 1, 0, -1.4]] {
                let voltage = canonical.map { polarity * $0 }
                let coordinate = dc(device, voltage)
                let csr = dc(device, voltage, csr: true)
                let collector = L3Stamps()
                var stamper = ComplexMatrixStamper(variableMap: variableMap,
                    stampMatrix: { collector.matrix($0, $1, $2, $3) }, stampRHS: { _, _, _ in })
                device.stampAC(into: &stamper,
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
            let p: [String: ParameterValue] = [
                "kp": .real(0), "w": .real(1), "l": .real(1),
                "cgso": .real(1e-12), "cgdo": .real(3e-12),
                "cj": .real(1e-3), "ad": .real(2e-12), "as": .real(1e-12)
            ]
            let device = try bind(polarity: polarity, parameters: p)
            for drainBias in [-1.0, 1.0] {
                let voltage = [drainBias, 0, 0, -2].map { polarity * $0 }
                let collector = L3Stamps()
                var stamper = ComplexMatrixStamper(variableMap: variableMap,
                    stampMatrix: { collector.matrix($0, $1, $2, $3) }, stampRHS: { _, _, _ in })
                device.stampAC(into: &stamper,
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
            let device = try bind(polarity: polarity, parameters: [
                "kp": .real(0), "w": .real(1), "l": .real(1),
                "cgso": .real(1e-12), "cgdo": .real(3e-12)
            ])
            let integration = IntegrationState(method: .trapezoidal, timeStep: 1, currentTime: 1)
            let first = [1.0, 4, 0, 0].map { polarity * $0 }
            let accepted = SolutionState(variables: first, previousVariables: [0, 0, 0, 0],
                                         variableMap: variableMap)
            let committing = try #require(device as? any TransientStateCommittingDevice)
            committing.commitTransientStep(state: accepted, integration: integration)
            let next = [-1.0, 4, 0, 0].map { polarity * $0 }
            let collector = L3Stamps()
            var stamper = MatrixStamper(variableMap: variableMap,
                stampMatrix: { collector.matrix($0, $1, $2) }, stampRHS: { collector.rhs($0, $1) })
            device.stampTransient(into: &stamper,
                state: SolutionState(variables: next, previousVariables: first, variableMap: variableMap),
                integration: integration)
            let stamp = collector.values
            let channel = dc(device, next)
            close(stamp.real[5] - channel.real[5], 8e-12, absolute: 1e-25)
            close(stamp.rhs[1] - channel.rhs[1], polarity * 52e-12, absolute: 1e-25)
            close(stamp.rhs[0] - channel.rhs[0], -polarity * 36e-12, absolute: 1e-25)
            close(stamp.rhs[2] - channel.rhs[2], -polarity * 16e-12, absolute: 1e-25)
        }
    }

    private func prepared(polarity: Double, overrides: [String: ParameterValue] = [:]) throws -> (PreparedCircuit, [Double], [Branch]) {
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
        var p = parameters(polarity: polarity)
        p["cgso"] = .real(1e-10)
        p.merge(overrides) { _, replacement in replacement }
        try netlist.addInstance(name: "M1", typeName: polarity == 1 ? "nmos_l3" : "pmos_l3",
            nodes: ["n0", "n1", "n2", "n3"], parameters: p)
        let ir = try netlist.build()
        let plan = try StandardCompiler().compile(ir: ir)
        let structure = plan.matrixStructure
        var context = BindingContext(variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension,
            stampIndexResolver: { structure.index(row: $0, col: $1) })
        let devices = try ir.instances.map { instance -> any BoundDevice in
            let descriptor = try #require(DeviceRegistry.standard().descriptor(for: instance.typeName))
            return try descriptor.bind(instance: instance, context: &context)
        }
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
            p["cgso"] = .real(1e-10)
            let local = try bind(polarity: polarity, parameters: p)
            let stamp = dc(local, voltage)
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
            let config = TransientConfig(stopTime: 3e-9, maxTimeStep: 1e-9, initialTimeStep: 1e-9)
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
            "theta": .real(0), "kappa": .real(0), "eta": .real(0)
        ])
        let nodes = try #require(circuit.devices.last).instance.nodes
        let analysis = DCAnalysis(nodeInitialGuess: [nodes[0]: 1e200, nodes[1]: 1e200])
        do {
            _ = try await analysis.run(circuit: circuit, solver: SparseLUSolver(), observer: nil,
                                       cancellation: CancellationToken())
            Issue.record("Overflowing L3 channel produced successful DC evidence")
        } catch let error as AnalysisError {
            switch error {
            case .nonFiniteSolution, .nonFiniteResidual: break
            default: Issue.record("Expected a numerical-failure diagnostic, got \(error)")
            }
        }
    }
}

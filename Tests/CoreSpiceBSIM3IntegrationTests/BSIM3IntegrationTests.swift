@testable import CoreSpice
import CoreSpiceMOSContracts
import CoreSpiceParserSPICE
import CoreSpiceParsedIR
import CoreSpiceLowering
import CoreSpiceDevices
import CoreSpiceCompactModels
import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceIR
import CoreSpiceEvent
import CoreSpiceIO
import Foundation
import Synchronization
import Testing

@Suite("Native BSIM3 production composition", .timeLimit(.minutes(1)))
struct BSIM3IntegrationTests {
    private func source(sign: Double = 1, capmod: Double = 3, tox: String = "10n",
                        extraModel: String = "", extraInstance: String = "",
                        version: String = "version=3.3.0", gate: String? = nil, second: Bool = false) -> String {
        """
        native BSIM3 production circuit
        .model process \(sign == 1 ? "nmos" : "pmos") level=49 \(version) vth0=\(sign * 0.7) u0=500 tox=\(tox)
        + capmod=\(capmod) cj=1m cjsw=0.1n cgdo=0.2n cgso=0.3n \(extraModel)
        VD d 0 \(sign)
        VG g 0 \(gate ?? String(sign * 1.2)) ac \(sign)
        VS s 0 0
        VB b 0 \(-sign * 0.1)
        M1 d g s b process w=10u l=1u ad=2p as=3p pd=12u ps=14u \(extraInstance)
        \(second ? "M2 d g s b process w=10u l=1u nqsmod=1" : "")
        .end
        """
    }
    private func parsed(_ text: String) async throws -> ParsedNetlist {
        try await SPICEParser().parse(source: text).get()
    }
    private func prepared(_ text: String, temperature: Double = 300.15,
                          capabilities: MOSAnalysisCapabilities = [.dc, .ac, .transient]) async throws -> PreparedNativeCircuit {
        try await NativeBSIMFixture.prepare(text, temperature: temperature, capabilities: capabilities)
    }
    private func boundFixture(_ text: String, temperature: Double = 300.15) async throws -> BoundBSIMFixture {
        BoundBSIMFixture(try await prepared(text, temperature: temperature))
    }
    private func mos(_ circuit: borrowing PreparedNativeCircuit) throws -> (instance: Instance, receipt: MOSPreparationReceipt) {
        try NativeBSIMFixture.mos(circuit)
    }
    private func mos(_ circuit: BoundBSIMFixture) throws -> any BoundDevice {
        try #require(circuit.devices.first { $0.instance.name == "m1" })
    }
    private func close(_ actual: Double, _ expected: Double, relative: Double = 2e-5, absolute: Double = 1e-12,
                       sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        #expect(abs(actual - expected) <= absolute + relative * max(abs(actual), abs(expected)),
                "actual=\(actual), expected=\(expected)", sourceLocation: sourceLocation)
    }
    private struct Stamp {
        var matrix: [[Double]]
        var rhs: [Double]
        func residual(_ values: [Double]) -> [Double] {
            matrix.enumerated().map { row, columns in
                zip(columns, values).reduce(-rhs[row]) { $0 + $1.0 * $1.1 }
            }
        }
    }
    private func stamp(_ device: any BoundDevice, circuit: BoundBSIMFixture, values: [Double],
                       integration: IntegrationState? = nil, direct: Bool = false) throws -> Stamp {
        var matrix = SparseMatrix(structure: circuit.plan.matrixStructure)
        var rhs = [Double](repeating: 0, count: values.count)
        var stamper = MatrixStamper(variableMap: circuit.plan.topology.variableMap,
            stampMatrix: { matrix.addValue(row: $0, col: $1, value: $2) },
            stampRHS: { rhs[$0] += $1 }, stampValue: direct ? { matrix.addValueDirect(at: $0, value: $1) } : nil)
        let state = SolutionState(variables: values, variableMap: circuit.plan.topology.variableMap)
        if let integration { try device.stampTransient(into: &stamper, state: state, integration: integration) }
        else { try device.stampDC(into: &stamper, state: state) }
        #expect(matrix.structuralMisses.isEmpty)
        return Stamp(matrix: matrix.toDense(), rhs: rhs)
    }
    private func bias(_ circuit: BoundBSIMFixture, sign: Double = 1) throws -> [Double] {
        let device = try mos(circuit)
        var values = [Double](repeating: 0, count: circuit.plan.topology.dimension)
        for (index, node) in device.instance.nodes.enumerated() {
            values[try #require(circuit.plan.topology.nodeIndex(node))] = [sign, sign * 1.2, 0, -sign * 0.1][index]
        }
        for (index, node) in device.instance.ownedNodes.enumerated() {
            values[try #require(circuit.plan.topology.nodeIndex(node))] = [sign * 0.95, sign * 0.02, 1e-6][index]
        }
        return values
    }

    @Test func frontendPreservesExactVersion() async throws {
        for literal in ["3.3.0", "\"3.3.0\"", "3.30.0"] {
            let netlist = try await parsed(source(extraInstance: "off ic=0.5,1.1,-0.2", version: "version=\(literal)"))
            guard case .string(let version) = try #require(netlist.models.first).parameters["version"] else {
                Issue.record("Exact model version was converted to a numeric value"); return
            }
            #expect(version == literal.replacingOccurrences(of: "\"", with: ""))
            let instance = try #require(netlist.components.first { $0.type == .mosfet })
            #expect(instance.parameters["off"] == .boolean(true))
            #expect(instance.parameters["ic_vds"] == .numeric(0.5))
            #expect(instance.parameters["ic_vgs"] == .numeric(1.1))
            #expect(instance.parameters["ic_vbs"] == .numeric(-0.2))
        }
        let invalid = await SPICEParser().parse(source: "title\nR1 d 0 3.3.0\n.end\n")
        #expect(invalid.hasErrors)
        let invalidIC = await SPICEParser().parse(source: source(extraInstance: "ic=1,2,3,4"))
        #expect(invalidIC.hasErrors)
    }

    @Test func nativeSelectorAdmitsOriginalModel() async throws {
        let circuit = try await prepared(source(extraModel: "rsh=20 acnqsmod=0", extraInstance: "nqsmod=1 acnqsmod=1"))
        let device = try mos(circuit)
        #expect(device.instance.typeName == "nmos_l49")
        let resolved = device.receipt.identity.resolved
        #expect(resolved.symbolNames[Int(resolved.selectedName.rawValue)] == "process")
        #expect(NativeBSIMFixture.value("acnqsmod", in: resolved.modelCoefficients, resolved: resolved) == 0)
        #expect(NativeBSIMFixture.value("acnqsmod", in: resolved.instanceParameters, resolved: resolved) == 1)
        #expect(NativeBSIMFixture.value("vth0", in: resolved.instanceParameters, resolved: resolved) == nil)
        #expect(device.instance.ownedNodes.count == 3)
        let (lowered, _) = try await NativeBSIMFixture.frontend(source())
        guard case .resolved = lowered.circuit.instances.last?.mos else {
            Issue.record("Frontend did not preserve typed model resolution"); return
        }
        let report = SPICEDeckCoverageReport.generate(from: try await parsed(source()))
        #expect(!report.hasBlockedItems)
    }

    @Test func auxiliaryTopologyAndAdmissionFailuresRemainExplicit() async throws {
        for (model, instance, count) in [("", "", 0), ("rsh=20", "", 2), ("", "nqsmod=1", 1), ("rsh=20", "nqsmod=1", 3)] {
            let circuit = try await prepared(source(extraModel: model, extraInstance: instance, second: true))
            let device = try mos(circuit)
            #expect(device.instance.ownedNodes.count == count)
            let other = try #require(circuit.plan.ir.instances.last)
            #expect(Set(device.instance.ownedNodes).isDisjoint(with: other.ownedNodes))
            let indices = (device.instance.nodes + device.instance.ownedNodes).compactMap { circuit.plan.topology.nodeIndex($0) }
            for row in indices { for column in indices {
                #expect(circuit.plan.matrixStructure.index(row: row, col: column) != nil)
            } }
            if count > 0 {
                let bad = Instance(name: device.instance.name, typeName: device.instance.typeName,
                    nodes: device.instance.nodes, parameters: [:], mos: .prepared(device.receipt))
                #expect(throws: MOSBindingFailure.topologyMismatch) {
                    try NativeBSIMFixture.rebind(bad, receipt: device.receipt, record: circuit.record)
                }
            }
        }
        for version in ["3.3.1", "3.30.0", "4.0"] {
            do { _ = try await prepared(source(version: "version=\(version)")); Issue.record("Unknown version admitted") }
            catch let error as MOSResolutionFailure { #expect(error == .schema(.unsupportedRelease(level: 49, version: version))) }
        }
        do { _ = try await prepared(source(tox: "0")); Issue.record("Invalid model admitted") }
        catch let error as SPICENativePreparationError { guard case .mosPreparation(.kernelRejected) = error else { Issue.record("Unexpected error \(error)"); return } }
        do { _ = try await prepared(source(extraInstance: "vth0=0.9")); Issue.record("Instance overwrote model semantics") }
        catch let error as MOSResolutionFailure { #expect(error == .schema(.unknownParameter(name: "vth0", role: .instance, release: .bsim3_3_3_0))) }
    }

    @Test func boundCurrentAndTransientJacobiansMatchFiniteDifferences() async throws {
        for sign in [1.0, -1.0] {
            for nqs in [false, true] {
                let circuit = try await boundFixture(source(sign: sign, extraModel: "rsh=20", extraInstance: nqs ? "nqsmod=1 m=2" : "m=2"))
                let device = try mos(circuit)
                let values = try bias(circuit, sign: sign)
                let session = try #require(device as? any TransientSessionDevice)
                try session.beginTransientSession(initialState: SolutionState(variables: values, variableMap: circuit.plan.topology.variableMap))
                defer { session.endTransientSession() }
                let active = (device.instance.nodes + device.instance.ownedNodes).compactMap { circuit.plan.topology.nodeIndex($0) }
                for integration in [nil, IntegrationState(method: .backwardEuler, timeStep: 1e-9, currentTime: 1e-9),
                                    IntegrationState(method: .trapezoidal, timeStep: 1e-9, currentTime: 1e-9)] {
                    let center = try stamp(device, circuit: circuit, values: values, integration: integration)
                    let direct = try stamp(device, circuit: circuit, values: values, integration: integration, direct: true)
                    #expect(center.matrix == direct.matrix)
                    #expect(center.rhs == direct.rhs)
                    for column in active {
                        var plus = values, minus = values
                        plus[column] += 1e-6; minus[column] -= 1e-6
                        let p = try stamp(device, circuit: circuit, values: plus, integration: integration).residual(plus)
                        let m = try stamp(device, circuit: circuit, values: minus, integration: integration).residual(minus)
                        for row in active { close(center.matrix[row][column], (p[row] - m[row]) / 2e-6, relative: 4e-4) }
                    }
                }
            }
        }
    }

    @Test func productionDCMatchesIndependentFixtures() async throws {
        struct Oracle: Decodable {
            struct Case: Decodable { let polarity: String; let bias: [Double]; let temperature: Double; let capmod: Double; let expected: [String: Double] }
            let cases: [Case]
        }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CoreSpiceCompactModelsTests/Fixtures/oracle.json")
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: fixture))
        #expect(oracle.cases.count == 18)
        for item in oracle.cases {
            let sign = item.polarity == "nmos" ? 1.0 : -1.0
            let text = source(sign: sign, capmod: item.capmod)
                .replacingOccurrences(of: "VD d 0 \(sign)", with: "VD d 0 \(item.bias[1])")
                .replacingOccurrences(of: "VB b 0 \(-sign * 0.1)", with: "VB b 0 \(item.bias[4])")
                .replacingOccurrences(of: "VG g 0 \(sign * 1.2)", with: "VG g 0 \(item.bias[2])")
            let circuit = try await prepared(text, temperature: item.temperature)
            let plan = circuit.plan
            let result = try await DCAnalysis().run(circuit: consume circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
            let drain = try #require(plan.ir.branchNames.first { $0.value == "vd" }?.key)
            let index = try #require(plan.topology.variableMap[.branchCurrent(drain)])
            close(result.variables[index], try #require(item.expected["dCurrent"]), relative: 5e-8, absolute: 5e-12)
        }
    }

    @Test func actualACAndDynamicTransientUseSeriesAndNQS() async throws {
        for sign in [1.0, -1.0] {
            for nqs in [false, true] {
                let circuit = try await prepared(source(sign: sign, extraModel: "rsh=20 acnqsmod=\(nqs ? 1 : 0)",
                    extraInstance: nqs ? "nqsmod=1" : "", gate: "sin(\(sign * 1.2) \(sign * 0.03) 100Meg)"))
                let plan = circuit.plan
                let dc = try await DCAnalysis().run(circuit: consume circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
                let ac = try await ACAnalysis(sweep: .linear(start: 1e8, stop: 1e8, points: 1))
                    .run(circuit: try await prepared(source(sign: sign, extraModel: "rsh=20 acnqsmod=\(nqs ? 1 : 0)",
                    extraInstance: nqs ? "nqsmod=1" : "", gate: "sin(\(sign * 1.2) \(sign * 0.03) 100Meg)")), solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
                #expect(ac.solutions[0].allSatisfy { $0.real.isFinite && $0.imag.isFinite })
                let gate = try #require(plan.ir.branchNames.first { $0.value == "vg" }?.key)
                let gateIndex = try #require(plan.topology.variableMap[.branchCurrent(gate)])
                #expect(abs(ac.solutions[0][gateIndex].imag) > 1e-7)
                let config = TransientConfig(stopTime: 2e-9, executionLimits: .validationFixture, maxTimeStep: 2e-11, initialTimeStep: 2e-12)
                let run = TransientAnalysis(config: config)
                let first = try await run.run(circuit: try await prepared(source(sign: sign, extraModel: "rsh=20 acnqsmod=\(nqs ? 1 : 0)",
                    extraInstance: nqs ? "nqsmod=1" : "", gate: "sin(\(sign * 1.2) \(sign * 0.03) 100Meg)")), solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
                #expect(first.timePoints.last == config.stopTime)
                #expect(first.timeSteps > 20)
                let last = try first.withSolution(at: first.timePoints.count - 1) { Array($0) }
                #expect(last.allSatisfy { $0.isFinite })
                let drain = try #require(plan.ir.branchNames.first { $0.value == "vd" }?.key)
                let drainIndex = try #require(plan.topology.variableMap[.branchCurrent(drain)])
                #expect(abs(last[drainIndex] - dc.variables[drainIndex]) > 1e-6)
                let repeated = try await run.run(circuit: try await prepared(source(sign: sign, extraModel: "rsh=20 acnqsmod=\(nqs ? 1 : 0)",
                    extraInstance: nqs ? "nqsmod=1" : "", gate: "sin(\(sign * 1.2) \(sign * 0.03) 100Meg)")), solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
                #expect(first.timePoints == repeated.timePoints)
                for index in first.timePoints.indices {
                    close(try first.value(variableIndex: drainIndex, timeIndex: index),
                          try repeated.value(variableIndex: drainIndex, timeIndex: index), absolute: 1e-15)
                }
            }
        }
    }

    @Test func actualACAndTransientMatchIndependentTerminalOracle() async throws {
        struct Oracle: Decodable {
            struct Case: Decodable { let name: String; let source: String; let ac: [Double]; let transient: [[Double]] }
            let cases: [Case]
        }
        let path = try #require(Bundle.module.url(forResource: "analysis-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: path))
        #expect(oracle.cases.count == 4)
        for fixture in oracle.cases {
            let circuit = try await prepared(fixture.source)
            let plan = circuit.plan
            let drain = try #require(plan.ir.branchNames.first { $0.value == "vd" }?.key)
            let gate = try #require(plan.ir.branchNames.first { $0.value == "vg" }?.key)
            let drainIndex = try #require(plan.topology.variableMap[.branchCurrent(drain)])
            let gateIndex = try #require(plan.topology.variableMap[.branchCurrent(gate)])
            let ac = try await ACAnalysis(sweep: .linear(start: 1e8, stop: 1e8, points: 1),
                dcConfig: .init(abstol: 1e-15, reltol: 1e-7, vntol: 1e-9, gmin: 0))
                .run(circuit: consume circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
            close(ac.solutions[0][drainIndex].real, fixture.ac[1], relative: 1e-7, absolute: 2e-12)
            close(ac.solutions[0][drainIndex].imag, fixture.ac[2], relative: 1e-7, absolute: 2e-12)
            close(ac.solutions[0][gateIndex].real, fixture.ac[3], relative: 1e-7, absolute: 2e-12)
            close(ac.solutions[0][gateIndex].imag, fixture.ac[4], relative: 1e-7, absolute: 2e-12)
            let transient = try await TransientAnalysis(config: .init(stopTime: 2e-9, executionLimits: .validationFixture, maxTimeStep: 2e-12, initialTimeStep: 2e-12),
                convergenceConfig: .init(abstol: 1e-15, reltol: 1e-7, vntol: 1e-9, gmin: 0))
                .run(circuit: try await prepared(fixture.source), solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
            for point in fixture.transient {
                let right = try #require(transient.timePoints.firstIndex { $0 >= point[0] - 1e-21 })
                let left = max(0, right - 1)
                let span = transient.timePoints[right] - transient.timePoints[left]
                let fraction = span == 0 ? 0 : (point[0] - transient.timePoints[left]) / span
                for (variable, column) in [(drainIndex, 1), (gateIndex, 2)] {
                    let low = try transient.value(variableIndex: variable, timeIndex: left)
                    let high = try transient.value(variableIndex: variable, timeIndex: right)
                    close(low + fraction * (high - low), point[column], relative: 3e-3, absolute: 5e-9)
                }
            }
        }
    }

    @Test func sessionAdmissionRejectedTrialsAndRunExitPreserveOwnership() async throws {
        let circuit = try await boundFixture(source(extraModel: "rsh=20", extraInstance: "nqsmod=1", second: true))
        let device = try mos(circuit)
        let session = try #require(device as? any TransientSessionDevice)
        let values = try bias(circuit)
        let initial = SolutionState(variables: values, variableMap: circuit.plan.topology.variableMap)
        let count = Mutex(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 { group.addTask {
                do { try session.beginTransientSession(initialState: initial); count.withLock { $0 += 1 } }
                catch let error as BSIM3DeviceError { #expect(error == .transientSessionAlreadyActive(device.instance.name)) }
            } }
            try await group.waitForAll()
        }
        #expect(count.withLock { $0 } == 1)
        let integration = IntegrationState(method: .trapezoidal, timeStep: 1e-9, currentTime: 1e-9)
        let baseline = try stamp(device, circuit: circuit, values: values, integration: integration)
        var rejected = values
        rejected[try #require(circuit.plan.topology.nodeIndex(device.instance.nodes[1]))] += 0.1
        _ = try stamp(device, circuit: circuit, values: rejected, integration: integration)
        let afterRejected = try stamp(device, circuit: circuit, values: values, integration: integration)
        #expect(afterRejected.rhs == baseline.rhs)
        session.endTransientSession()
        let other = try #require(circuit.devices.last as? any TransientSessionDevice)
        try other.beginTransientSession(initialState: initial)
        defer { other.endTransientSession() }
        do {
            _ = try await TransientAnalysis(config: .init(stopTime: 1e-9, executionLimits: .validationFixture, useInitialConditions: true))
                .run(circuit: circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            Issue.record("Concurrent transient run admitted")
        } catch let error as BSIM3DeviceError {
            #expect(error == .transientSessionAlreadyActive("m2"))
        }
        // Partial acquisition released M1, while rejected M2 stayed active.
        try session.beginTransientSession(initialState: initial)
        session.endTransientSession()
        #expect(throws: BSIM3DeviceError.transientSessionAlreadyActive("m2")) {
            try other.beginTransientSession(initialState: initial)
        }
        other.endTransientSession()
        let cancellation = CancellationToken()
        let cancelledRun = TransientAnalysis(config: .init(stopTime: 2e-9, executionLimits: .validationFixture, maxTimeStep: 1e-10),
            onStepAccepted: { _, _ in cancellation.cancel() })
        do { _ = try await cancelledRun.run(circuit: circuit, solver: SparseLUSolver(), observer: nil, cancellation: cancellation)
            Issue.record("Cancellation produced successful evidence") }
        catch let error as AnalysisError { guard case .cancelled = error else { Issue.record("Unexpected failure \(error)"); return } }
        try session.beginTransientSession(initialState: initial)
        session.endTransientSession()
    }

    @Test func terminalICInitializesPhysicalPrimeAndChargeHistory() async throws {
        let circuit = try await prepared(source(extraModel: "rsh=20", extraInstance: "nqsmod=1 ic=0.5,1.1,-0.2"))
        let device = try mos(circuit)
        let result = try await TransientAnalysis(config: .init(stopTime: 2e-12, executionLimits: .validationFixture, maxTimeStep: 1e-12,
            initialTimeStep: 1e-12, useInitialConditions: true), convergenceConfig: .init(gmin: 0))
            .run(circuit: consume circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
        for (node, expected) in zip(device.instance.nodes, [0.5, 1.1, 0, -0.2]) {
            close(try result.voltage(at: node, timeIndex: 0), expected, absolute: 1e-15)
        }
        close(try result.voltage(at: device.instance.ownedNodes[0], timeIndex: 0), 0.5, absolute: 1e-15)
        close(try result.voltage(at: device.instance.ownedNodes[1], timeIndex: 0), 0, absolute: 1e-15)
        #expect(result.timePoints.last == 2e-12)
        let lower = try await boundFixture(source(extraModel: "rsh=20", extraInstance: "nqsmod=1 ic=0.5,1.1,-0.2"))
        _ = try await TransientAnalysis(config: .init(stopTime: 2e-12, executionLimits: .validationFixture, maxTimeStep: 1e-12,
            initialTimeStep: 1e-12, useInitialConditions: true), convergenceConfig: .init(gmin: 0))
            .run(circuit: lower, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
        let session = try #require(try mos(lower) as? any TransientSessionDevice)
        try session.beginTransientSession(initialState: SolutionState(variables: try bias(lower), variableMap: lower.plan.topology.variableMap))
        session.endTransientSession()
    }

    @Test func numericalAndNoiseFailuresReachProductionCaller() async throws {
        let circuit = try await prepared(source())
        let device = try mos(circuit)
        let bulk = device.instance.nodes[3]
        do {
            _ = try await DCAnalysis(nodeInitialGuess: [bulk: 1e200]).run(circuit: consume circuit,
                solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
            Issue.record("Overflowing original model produced successful DC evidence")
        } catch let error as SPICENativeExecutionError {
            guard case .numerical(let cause) = error else { Issue.record("Unexpected failure \(error)"); return }
            #expect(cause as? BSIM3Error == .nonFiniteEvaluation)
        }
        let failingNoise = try await prepared(source(extraModel: "noimod=1 kf=-1"), capabilities: [.dc, .ac, .noise])
        let noiseOutput = try mos(failingNoise).instance.nodes[0]
        do {
            _ = try await NoiseAnalysis(outputNode: noiseOutput, sweep: .linear(start: 1e3, stop: 1e3, points: 1))
                .run(circuit: consume failingNoise, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
            Issue.record("Invalid BSIM noise produced successful evidence")
        } catch let error as SPICENativeExecutionError {
            guard case .numerical(let cause) = error else { Issue.record("Unexpected failure \(error)"); return }
            #expect(cause as? BSIM3Error == .nonFiniteEvaluation)
        }
        let failing = try await prepared(source().replacingOccurrences(of: "VB b 0 -0.1", with: "VB b 0 sin(-0.1 1e200 100Meg)"))
        do {
            _ = try await TransientAnalysis(config: .init(stopTime: 2e-12, executionLimits: .validationFixture, maxTimeStep: 1e-12, initialTimeStep: 1e-12))
                .run(circuit: consume failing, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
            Issue.record("Runtime model failure produced successful transient evidence")
        } catch let error as SPICENativeExecutionError {
            guard case .numerical(let cause) = error else { Issue.record("Unexpected failure \(error)"); return }
            #expect(cause as? BSIM3Error == .nonFiniteEvaluation)
        }
        // Lower owner access proves failed numerical execution releases the acquired history session.
        let lower = try await boundFixture(source().replacingOccurrences(of: "VB b 0 -0.1", with: "VB b 0 sin(-0.1 1e200 100Meg)"))
        do {
            _ = try await TransientAnalysis(config: .init(stopTime: 2e-12, executionLimits: .validationFixture, maxTimeStep: 1e-12, initialTimeStep: 1e-12))
                .run(circuit: lower, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            Issue.record("Lower runtime model failure became success")
        } catch let error as BSIM3Error { #expect(error == .nonFiniteEvaluation) }
        let released = try #require(try mos(lower) as? any TransientSessionDevice)
        try released.beginTransientSession(initialState: SolutionState(variables: try bias(lower), variableMap: lower.plan.topology.variableMap))
        released.endTransientSession()
    }
}

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

@Suite("Native BSIM4 production composition", .timeLimit(.minutes(1)))
struct BSIM4IntegrationTests {
    private func source(sign: Double = 1, toxe: String = "10n", extraModel: String = "", extraInstance: String = "",
                        version: String = "version=4.8.3", gate: String? = nil, second: Bool = false) -> String {
        """
        native BSIM4 production circuit
        .options bsim4stressiterations=8
        .model process \(sign == 1 ? "nmos" : "pmos") level=54 \(version) vth0=\(sign * 0.7) u0=0.05 toxe=\(toxe)
        + capmod=2 cjs=1m cjd=1m cjsws=0.1n cjswd=0.1n cgdo=0.2n cgso=0.3n \(extraModel)
        VD d 0 \(sign)
        VG g 0 \(gate ?? String(sign * 1.2)) ac \(sign)
        VS s 0 0
        VB b 0 \(-sign * 0.1)
        M1 d g s b process w=10u l=1u ad=2p as=3p pd=12u ps=14u nrd=1 nrs=1 \(extraInstance)
        \(second ? "M2 d g s b process w=10u l=1u trnqsmod=1" : "")
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
        let device = try #require(try mos(circuit) as? BoundBSIM4)
        var values = [Double](repeating: 0, count: circuit.plan.topology.dimension)
        for (index, node) in device.instance.nodes.enumerated() {
            values[try #require(circuit.plan.topology.nodeIndex(node))] = [sign, sign * 1.2, 0, -sign * 0.1][index]
        }
        let t = device.topology
        for (role, value) in [(t.drainPrime, sign * 0.95), (t.sourcePrime, sign * 0.02),
            (t.gatePrime, sign * 1.2), (t.gateMid, sign * 1.2), (t.bodyPrime, -sign * 0.1),
            (t.drainBody, -sign * 0.1), (t.sourceBody, -sign * 0.1), (t.chargeNode, 0)] where role > 4 {
            values[try #require(circuit.plan.topology.nodeIndex(device.instance.ownedNodes[role - 5]))] = value
        }
        return values
    }

    @Test func preparationPolicyIsExplicitAndShared() async throws {
        let (lowered, options) = try await NativeBSIMFixture.frontend(source())
        #expect(options.bsim4PreparationPolicy?.maximumStressIterations == 8)
        let circuit = try await prepared(source())
        let record = circuit.record
        #expect(try mos(circuit).receipt.identity.conditions.maximumStressIterations == 8)
        #expect(lowered.circuit.instances.allSatisfy { $0.parameters["bsim4stressiterations"] == nil })
        let missing = SPICENativeExecutionLimits(maximumDeviceCount: 1024, maximumMatrixDimension: 2048,
            maximumAllocationBytes: 1_000_000_000)
        let mismatch = SPICENativeExecutionLimits(maximumDeviceCount: 1024, maximumMatrixDimension: 2048,
            maximumAllocationBytes: 1_000_000_000, mosPreparationLimits: record.limits.mosPreparationLimits,
            mosPreparationConditions: try .init(ambientKelvin: record.operatingConditions.temperatureKelvin + 1,
                nominalKelvin: record.operatingConditions.nominalTemperatureKelvin,
                analysisCapabilities: [.dc, .ac, .transient], maximumStressIterations: 8))
        for limits in [missing, mismatch] {
            do {
                _ = try NativeCircuitPreparer().prepare(ir: lowered.circuit, registry: options.deviceRegistry(),
                    operatingConditions: record.operatingConditions, limits: limits,
                    numericalLimits: record.numericalLimits, resources: record.resources)
                Issue.record("Missing or mismatched explicit preparation conditions admitted")
            } catch let error as SPICENativePreparationError {
                guard case .mosPreparation(.invalidConditions) = error else { Issue.record("Unexpected failure \(error)"); return }
            }
        }
        for invalid in ["0", "-1", "1.5", "4294967296", "1e200", "bad"] {
            let netlist = try await parsed(source().replacingOccurrences(of: "bsim4stressiterations=8", with: "bsim4stressiterations=" + invalid))
            let limits = try NativeBSIMFixture.resolutionLimits()
            let compiled = try NetlistLowering.compile(netlist, limits: limits)
            var session = try NetlistLowering.beginEvaluation(compiled, profile: .coreStrictV1, limits: limits, seed: 1)
            do {
                _ = try SPICEAnalysisOptions.resolve(from: compiled, session: &session)
                Issue.record("Invalid preparation policy admitted: \(invalid)")
            } catch is SPICEAnalysisOptionError {
                #expect(invalid != "bad")
            } catch let error as MOSResolutionFailure {
                #expect(invalid == "bad")
                let unresolved = try #require(compiled.snapshot.symbol(named: "bad"))
                #expect(error == .undefinedParameter(unresolved))
            }
        }
        #expect(throws: BSIM4Error.resourceBudgetExceeded) {
            try JSONDecoder().decode(BSIM4PreparationPolicy.self, from: Data(#"{"maximumStressIterations":0}"#.utf8))
        }
        do {
            _ = try await prepared(source(extraInstance: "nf=2 sa=1u sb=1u sd=1u").replacingOccurrences(of: "bsim4stressiterations=8", with: "bsim4stressiterations=1"))
            Issue.record("Stress work exceeding the caller budget admitted")
        } catch let error as SPICENativePreparationError {
            guard case .mosPreparation(.kernelRejected(let reason)) = error else { Issue.record("Unexpected failure \(error)"); return }
            #expect(reason.contains(String(describing: BSIM4Error.resourceBudgetExceeded)))
        }
    }

    @Test func frontendPreservesExactVersion() async throws {
        for literal in ["4.8.3", "\"4.8.3\"", "4.83"] {
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
        let invalid = await SPICEParser().parse(source: "title\nR1 d 0 4.8.3\n.end\n")
        #expect(invalid.hasErrors)
        let invalidIC = await SPICEParser().parse(source: source(extraInstance: "ic=1,2,3,4"))
        #expect(invalidIC.hasErrors)
    }

    @Test func nativeSelectorAdmitsOriginalModel() async throws {
        let circuit = try await prepared(source(extraModel: "rsh=20 acnqsmod=0", extraInstance: "trnqsmod=1 acnqsmod=1"))
        let device = try mos(circuit)
        #expect(device.instance.typeName == "nmos_l54")
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
        for (model, instance, count) in [("", "", 0), ("rsh=20", "", 2), ("", "trnqsmod=1", 1), ("rsh=20", "trnqsmod=1", 3), ("rsh=20", "rbodymod=1 rgatemod=3", 7), ("rsh=20", "rbodymod=1 rgatemod=3 trnqsmod=1", 8)] {
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
                for exposed in [false, true] {
                    var owned = device.instance.ownedNodes
                    owned[0] = exposed ? device.instance.nodes[0] : owned.last!
                    if !exposed, owned.count == 1 { continue }
                    let invalid = Instance(name: device.instance.name, typeName: device.instance.typeName,
                        nodes: device.instance.nodes, parameters: [:], mos: .prepared(device.receipt), ownedNodes: owned)
                    #expect(throws: MOSBindingFailure.invalidMatrixMapping) {
                        try NativeBSIMFixture.rebind(invalid, receipt: device.receipt, record: circuit.record)
                    }
                }
            }
        }
        for version in ["3.3.1", "3.30.0", "4.0"] {
            do { _ = try await prepared(source(version: "version=\(version)")); Issue.record("Unknown version admitted") }
            catch let error as MOSResolutionFailure { #expect(error == .schema(.unsupportedRelease(level: 54, version: version))) }
        }
        do { _ = try await prepared(source(toxe: "0")); Issue.record("Invalid model admitted") }
        catch let error as SPICENativePreparationError { guard case .mosPreparation(.kernelRejected) = error else { Issue.record("Unexpected error \(error)"); return } }
        do { _ = try await prepared(source(extraInstance: "vth0=0.9")); Issue.record("Instance overwrote model semantics") }
        catch let error as MOSResolutionFailure { #expect(error == .schema(.unknownParameter(name: "vth0", role: .instance, release: .bsim4_4_8_3))) }
    }

    @Test func boundCurrentAndTransientJacobiansMatchFiniteDifferences() async throws {
        for sign in [1.0, -1.0] {
            for nqs in [false, true] {
                let circuit = try await boundFixture(source(sign: sign, extraModel: "rsh=20", extraInstance: nqs ? "rbodymod=1 rgatemod=3 trnqsmod=1 m=2 mult_i=1.3 mult_q=0.8" : "rbodymod=1 rgatemod=3 m=2 mult_i=1.3 mult_q=0.8"))
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
                        for row in active {
                            let weighted = zip(center.matrix[row], values).reduce(abs(center.rhs[row])) { $0 + abs($1.0 * $1.1) }
                            let rounding = Double(values.count + 2) * Double.ulpOfOne * weighted / 1e-6
                            close(center.matrix[row][column], (p[row] - m[row]) / 2e-6, relative: 4e-4, absolute: 1e-12 + rounding)
                        }
                    }
                }
            }
        }
    }

    private struct Oracle: Decodable {
        struct DC: Decodable { let name: String; let source: String; let currents: [Double] }
        struct Case: Decodable { let name: String; let source: String; let ac: [[Double]]; let transient: [[Double]] }
        let dc: [DC]
        let analyses: [Case]
    }
    private func oracle() throws -> Oracle {
        let path = try #require(Bundle.module.url(forResource: "analysis-oracle", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: path))
    }
    private func branch(_ plan: ExecutionPlan, _ name: String) throws -> Int {
        let identity = try #require(plan.ir.branchNames.first { $0.value == name }?.key)
        return try #require(plan.topology.variableMap[.branchCurrent(identity)])
    }
    @Test func productionDCMatchesIndependentFixtures() async throws {
        let fixtures = try oracle().dc
        #expect(fixtures.count == 22)
        for item in fixtures {
            let circuit = try await prepared(item.source)
            let plan = circuit.plan
            let result = try await DCAnalysis(config: .init(abstol: 1e-15, reltol: 1e-7, vntol: 1e-9, gmin: 0))
                .run(circuit: consume circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
            for (name, value) in zip(["vd", "vg"], item.currents) {
                close(result.variables[try branch(plan, name)], value, relative: 2e-7, absolute: 2e-12)
            }
        }
    }

    @Test func actualACAndDynamicTransientUseSeriesAndNQS() async throws {
        for sign in [1.0, -1.0] {
            for nqs in [false, true] {
                let circuit = try await prepared(source(sign: sign, extraModel: "rsh=20 acnqsmod=\(nqs ? 1 : 0)",
                    extraInstance: nqs ? "trnqsmod=1" : "", gate: "sin(\(sign * 1.2) \(sign * 0.03) 100Meg)"))
                let plan = circuit.plan
                let dc = try await DCAnalysis().run(circuit: consume circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
                let ac = try await ACAnalysis(sweep: .linear(start: 1e8, stop: 1e8, points: 1))
                    .run(circuit: try await prepared(source(sign: sign, extraModel: "rsh=20 acnqsmod=\(nqs ? 1 : 0)",
                    extraInstance: nqs ? "trnqsmod=1" : "", gate: "sin(\(sign * 1.2) \(sign * 0.03) 100Meg)")), solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
                #expect(ac.solutions[0].allSatisfy { $0.real.isFinite && $0.imag.isFinite })
                let gate = try #require(plan.ir.branchNames.first { $0.value == "vg" }?.key)
                let gateIndex = try #require(plan.topology.variableMap[.branchCurrent(gate)])
                #expect(abs(ac.solutions[0][gateIndex].imag) > 1e-7)
                let config = TransientConfig(stopTime: 2e-9, executionLimits: .validationFixture, maxTimeStep: 2e-11, initialTimeStep: 2e-12)
                let run = TransientAnalysis(config: config)
                let first = try await run.run(circuit: try await prepared(source(sign: sign, extraModel: "rsh=20 acnqsmod=\(nqs ? 1 : 0)",
                    extraInstance: nqs ? "trnqsmod=1" : "", gate: "sin(\(sign * 1.2) \(sign * 0.03) 100Meg)")), solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
                #expect(first.timePoints.last == config.stopTime)
                #expect(first.timeSteps > 20)
                let last = try first.withSolution(at: first.timePoints.count - 1) { Array($0) }
                #expect(last.allSatisfy { $0.isFinite })
                let drain = try #require(plan.ir.branchNames.first { $0.value == "vd" }?.key)
                let drainIndex = try #require(plan.topology.variableMap[.branchCurrent(drain)])
                #expect(abs(last[drainIndex] - dc.variables[drainIndex]) > 1e-6)
                let repeated = try await run.run(circuit: try await prepared(source(sign: sign, extraModel: "rsh=20 acnqsmod=\(nqs ? 1 : 0)",
                    extraInstance: nqs ? "trnqsmod=1" : "", gate: "sin(\(sign * 1.2) \(sign * 0.03) 100Meg)")), solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
                #expect(first.timePoints == repeated.timePoints)
                for index in first.timePoints.indices {
                    close(try first.value(variableIndex: drainIndex, timeIndex: index),
                          try repeated.value(variableIndex: drainIndex, timeIndex: index), absolute: 1e-15)
                }
            }
        }
    }

    @Test func actualACAndTransientMatchIndependentTerminalOracle() async throws {
        let fixtures = try oracle().analyses
        #expect(fixtures.count == 6)
        for fixture in fixtures {
            let circuit = try await prepared(fixture.source)
            let plan = circuit.plan
            let drainIndex = try branch(plan, "vd"), gateIndex = try branch(plan, "vg")
            // gmin=0 proves the reserved NQS coordinate is explicitly constrained.
            let ac = try await ACAnalysis(sweep: .decade(start: 1e3, stop: 1e11, pointsPerDecade: 1),
                dcConfig: .init(abstol: 1e-12, reltol: 1e-7, vntol: 1e-9, gmin: 0))
                .run(circuit: consume circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
            #expect(ac.solutions.count == fixture.ac.count)
            for (index, point) in fixture.ac.enumerated() {
                close(ac.frequencies[index], point[0], relative: 1e-12)
                for (variable, offset) in [(drainIndex, 1), (gateIndex, 3)] {
                    close(ac.solutions[index][variable].real, point[offset], relative: 2e-7, absolute: 2e-12)
                    close(ac.solutions[index][variable].imag, point[offset + 1], relative: 2e-7, absolute: 2e-12)
                }
            }
            for method in [IntegrationMethod.backwardEuler] {
                let transient = try await TransientAnalysis(config: .init(stopTime: 2e-9, executionLimits: .validationFixture,
                    maxTimeStep: 2e-12, initialTimeStep: 2e-12, initialMethod: method),
                    convergenceConfig: .init(gmin: 0))
                    .run(circuit: try await prepared(fixture.source), solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
                #expect(transient.timePoints.last == 2e-9)
                // dt/period <= 2e-4 bounds first-order integration and interpolation.
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
    }

    @Test func sessionAdmissionRejectedTrialsAndRunExitPreserveOwnership() async throws {
        let circuit = try await boundFixture(source(extraModel: "rsh=20", extraInstance: "trnqsmod=1", second: true))
        let device = try mos(circuit)
        let session = try #require(device as? any TransientSessionDevice)
        let values = try bias(circuit)
        let initial = SolutionState(variables: values, variableMap: circuit.plan.topology.variableMap)
        let count = Mutex(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 { group.addTask {
                do { try session.beginTransientSession(initialState: initial); count.withLock { $0 += 1 } }
                catch let error as BSIM4DeviceError { #expect(error == .transientSessionAlreadyActive(device.instance.name)) }
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
        } catch let error as BSIM4DeviceError {
            #expect(error == .transientSessionAlreadyActive("m2"))
        }
        // Partial acquisition released M1, while rejected M2 stayed active.
        try session.beginTransientSession(initialState: initial)
        session.endTransientSession()
        #expect(throws: BSIM4DeviceError.transientSessionAlreadyActive("m2")) {
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
        let circuit = try await prepared(source(extraModel: "rsh=20", extraInstance: "rbodymod=1 rgatemod=3 trnqsmod=1 ic=0.5,1.1,-0.2"))
        let device = try mos(circuit)
        let result = try await TransientAnalysis(config: .init(stopTime: 2e-12, executionLimits: .validationFixture, maxTimeStep: 1e-12,
            initialTimeStep: 1e-12, useInitialConditions: true), convergenceConfig: .init(gmin: 0))
            .run(circuit: consume circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
        for (node, expected) in zip(device.instance.nodes, [0.5, 1.1, 0, -0.2]) {
            close(try result.voltage(at: node, timeIndex: 0), expected, absolute: 1e-15)
        }
        let owned = try #require(device.instance.ownedNodes.count == 8 ? device.instance.ownedNodes : nil)
        close(try result.voltage(at: owned[0], timeIndex: 0), 0.5, absolute: 1e-15)
        close(try result.voltage(at: owned[1], timeIndex: 0), 0, absolute: 1e-15)
        let t = device.receipt.topology
        for (role, expected) in [(t.gatePrime, 1.1), (t.gateMid, 1.1), (t.bodyPrime, -0.2),
            (t.drainBody, -0.2), (t.sourceBody, -0.2), (t.chargeNode, 0.0)] where role > 4 {
            let node = owned[role - 5]
            close(try result.voltage(at: node, timeIndex: 0), expected, absolute: 1e-15)
        }
        #expect(result.timePoints.last == 2e-12)
        let lower = try await boundFixture(source(extraModel: "rsh=20", extraInstance: "rbodymod=1 rgatemod=3 trnqsmod=1 ic=0.5,1.1,-0.2"))
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
            #expect(cause as? BSIM4Error == .nonFiniteEvaluation)
        }
        let failingNoise = try await prepared(source())
        let noiseOutput = try mos(failingNoise).instance.nodes[0]
        do {
            _ = try await NoiseAnalysis(outputNode: noiseOutput, sweep: .linear(start: 1e3, stop: 1e3, points: 1))
                .run(circuit: consume failingNoise, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
            Issue.record("Invalid BSIM noise produced successful evidence")
        } catch let error as SPICENativeExecutionError {
            guard case .mosPreparation(.invalidConditions) = error else { Issue.record("Unexpected noise admission failure \(error)"); return }
        }
        let failing = try await prepared(source().replacingOccurrences(of: "VB b 0 -0.1", with: "VB b 0 sin(-0.1 1e200 100Meg)"))
        do {
            _ = try await TransientAnalysis(config: .init(stopTime: 2e-12, executionLimits: .validationFixture, maxTimeStep: 1e-12, initialTimeStep: 1e-12))
                .run(circuit: consume failing, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
            Issue.record("Runtime model failure produced successful transient evidence")
        } catch let error as SPICENativeExecutionError {
            guard case .numerical(let cause) = error else { Issue.record("Unexpected failure \(error)"); return }
            #expect(cause as? BSIM4Error == .nonFiniteEvaluation)
        }
        // Lower owner access proves failed numerical execution releases the acquired history session.
        let lower = try await boundFixture(source().replacingOccurrences(of: "VB b 0 -0.1", with: "VB b 0 sin(-0.1 1e200 100Meg)"))
        do {
            _ = try await TransientAnalysis(config: .init(stopTime: 2e-12, executionLimits: .validationFixture, maxTimeStep: 1e-12, initialTimeStep: 1e-12))
                .run(circuit: lower, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
            Issue.record("Lower runtime model failure became success")
        } catch let error as BSIM4Error { #expect(error == .nonFiniteEvaluation) }
        let released = try #require(try mos(lower) as? any TransientSessionDevice)
        try released.beginTransientSession(initialState: SolutionState(variables: try bias(lower), variableMap: lower.plan.topology.variableMap))
        released.endTransientSession()
    }
}

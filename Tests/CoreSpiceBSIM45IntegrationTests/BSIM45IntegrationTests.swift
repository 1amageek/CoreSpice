@testable import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceCompactModels
import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceIO
import CoreSpiceMOSContracts
import Foundation
import Testing

@Suite("Exact BSIM4 4.5 public native composition", .timeLimit(.minutes(1)))
struct BSIM45IntegrationTests {
    private let names = ["rd", "rs", "rg", "rbps", "rbpd", "rbpb", "rbsb", "rbdb", "id", "1overf", "igs", "igd", "igb"]
    private func source(sign: Double = 1, nqs: Bool = false, rf: Bool = false, noise: Bool = false,
                        dynamic: Bool = false, multiplier: Double = 3) -> String {
        """
        Exact 4.5 public composition
        .options bsim4stressiterations=8
        .model process \(sign == 1 ? "nmos" : "pmos") level=54 version=4.5.0 vth0=\(sign * 0.7) u0=.05 toxe=10n
        + acnqsmod=\(nqs ? 1 : 0) trnqsmod=\(nqs ? 1 : 0) rsh=\(rf ? 20 : 0) rbodymod=\(rf ? 1 : 0) rgateMod=\(rf ? 3 : 0)
        + tnoimod=1 fnoimod=0 kf=1e-25
        VD \(noise ? "supply" : "d") 0 \(noise ? sign * 2 : sign)
        \(noise ? "RL supply d 1k" : "")
        VG g 0 \(dynamic ? "sin(\(sign * 1.2) \(sign * 0.01) 10Meg)" : String(sign * 1.2)) ac \(sign)
        VS s 0 0
        VB b 0 \(-sign * 0.1)
        M1 d g s b process l=1u w=10u nf=2 nrd=1 nrs=1 m=\(multiplier)
        .end
        """
    }
    private func parameter(_ name: String, _ value: Double, role: MOSParameterRole = .model) throws -> BSIM45Parameter {
        let definition = try MOSModelSchema(release: .bsim4_4_5).parameter(named: name, role: role)
        guard case .native(let id) = definition.authority else { throw BSIM45Error.invalidSchema }
        return .init(id: id, kind: definition.kind, value: value)
    }
    private func reference(sign: Double = 1, nqs: Bool = false, rf: Bool = false, noise: Bool = false, temperature: Double = 300.15, nominal: Double = 300.15) throws -> BSIM45Evaluator {
        try BSIM45Evaluator(configuration: .init(polarity: sign == 1 ? .nmos : .pmos,
            temperature: temperature, nominalTemperature: nominal, noiseRequested: noise, maximumStressIterations: 8,
            modelParameters: [parameter("vth0", sign * 0.7), parameter("u0", 0.05), parameter("toxe", 1e-8),
                parameter("acnqsmod", nqs ? 1 : 0), parameter("trnqsmod", nqs ? 1 : 0),
                parameter("rsh", rf ? 20 : 0), parameter("rbodymod", rf ? 1 : 0), parameter("rgatemod", rf ? 3 : 0),
                parameter("tnoimod", 1), parameter("fnoimod", 0), parameter("kf", 1e-25)],
            instanceParameters: [parameter("l", 1e-6, role: .instance), parameter("w", 1e-5, role: .instance),
                parameter("nf", 2, role: .instance), parameter("nrd", 1, role: .instance), parameter("nrs", 1, role: .instance)]))
    }
    private func close(_ actual: Double, _ expected: Double, absolute: Double = 2e-11, relative: Double = 2e-7,
                       sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        #expect(abs(actual - expected) <= absolute + relative * max(abs(actual), abs(expected)),
            "actual=\(actual) expected=\(expected)", sourceLocation: sourceLocation)
    }
    private func branch(_ plan: ExecutionPlan, _ name: String) throws -> Int {
        let branch = try #require(plan.ir.branchNames.first { $0.value == name }?.key)
        return try #require(plan.topology.variableMap[.branchCurrent(branch)])
    }
    private func local(_ values: [Double], instance: Instance, plan: ExecutionPlan, chargeNode: Int) throws -> SIMD16<Double> {
        var result = SIMD16<Double>.zero
        for (index, node) in (instance.nodes + instance.ownedNodes).enumerated() where node != .ground && index + 1 != chargeNode {
            result[index + 1] = values[try #require(plan.topology.nodeIndex(node))]
        }
        return result
    }

    @Test func publicDCAndACPreserveExactOwnerMAndFullTopology() async throws {
        for sign in [1.0, -1.0] { for nqs in [false, true] { for rf in [false, true] {
            let deck = source(sign: sign, nqs: nqs, rf: rf)
            let circuit = try await NativeBSIM45Fixture.prepare(deck, capabilities: [.dc, .ac])
            let plan = circuit.plan, record = circuit.record
            let (instance, receipt) = try NativeBSIM45Fixture.mos(circuit)
            #expect(receipt.identity.resolved.release == .bsim4_4_5 && receipt.coldSetupCount == 1)
            #expect(record.bsim45Models.count == 1 && record.bsim4Models.isEmpty)
            #expect(record.bsim45Models[0].implementationIdentity.hasSuffix(BSIM45Evaluator.adaptationIdentity))
            #expect(receipt.retainedBytes >= BSIM45Evaluator.ownerAllocationBytes + BSIM45Evaluator.storedPayloadBytes)
            let owner = try reference(sign: sign, nqs: nqs, rf: rf)
            #expect(owner.topology.nodeCount == receipt.topology.localNodeCount)
            let dc = try await DCAnalysis(config: .init(abstol: 1e-13, reltol: 1e-8, vntol: 1e-10, gmin: 0))
                .run(circuit: consume circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
            let bias = try local(dc.variables, instance: instance, plan: plan, chargeNode: owner.topology.chargeNode)
            let expected = try owner.evaluate(bias: bias, analysis: .dc)
            for (port, name) in ["vd", "vg", "vs", "vb"].enumerated() {
                close(dc.variables[try branch(plan, name)], -3 * expected.residual[port + 1])
            }
            if nqs {
                let q = try #require(plan.topology.nodeIndex(instance.ownedNodes[owner.topology.chargeNode - 5]))
                #expect(dc.variables[q] == 0)
            }
            let ac = try await ACAnalysis(sweep: .linear(start: 1e8, stop: 1e8, points: 1),
                dcConfig: .init(abstol: 1e-13, reltol: 1e-8, vntol: 1e-10, gmin: 0))
                .run(circuit: try await NativeBSIM45Fixture.prepare(deck, capabilities: [.dc, .ac]),
                    solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
            let y = try owner.evaluate(bias: bias, analysis: .ac(angularFrequency: 2 * .pi * 1e8))
            for (port, name) in ["vd", "vg", "vs", "vb"].enumerated() {
                var current = ComplexPair.zero
                for (column, node) in (instance.nodes + instance.ownedNodes).enumerated() where node != .ground {
                    let voltage = ac.solutions[0][try #require(plan.topology.nodeIndex(node))]
                    let slot = (port + 1) * 16 + column + 1
                    current = current + ComplexPair(real: y.realJacobian[slot], imag: y.imaginaryJacobian[slot]) * voltage
                }
                let actual = ac.solutions[0][try branch(plan, name)]
                close(actual.real, -3 * current.real); close(actual.imag, -3 * current.imag)
            }
        } } }
    }

    @Test func publicPreparationUsesExplicitAmbientAndNominalTemperatures() async throws {
        let deck = source().replacingOccurrences(of: "bsim4stressiterations=8", with: "bsim4stressiterations=8 tnom=45")
        let circuit = try await NativeBSIM45Fixture.prepare(deck, temperature: 350, capabilities: .dc)
        let plan = circuit.plan, (instance, receipt) = try NativeBSIM45Fixture.mos(circuit)
        #expect(receipt.identity.conditions.ambientKelvin == 350 && receipt.identity.conditions.nominalKelvin == 318.15)
        let result = try await DCAnalysis(config: .init(gmin: 0)).run(circuit: consume circuit,
            solver: SparseLUSolver(), observer: nil, cancellation: .init()).result
        let owner = try reference(temperature: 350, nominal: 318.15)
        let expected = try owner.evaluate(bias: local(result.variables, instance: instance, plan: plan,
            chargeNode: owner.topology.chargeNode), analysis: .dc)
        close(result.variables[try branch(plan, "vd")], -3 * expected.residual[1])
    }

    @Test func publicBEAndTRReplayAcceptedHistoryAndDeficit() async throws {
        for nqs in [false, true] { for initialMethod in [IntegrationMethod.backwardEuler, .trapezoidal] {
            let deck = source(nqs: nqs, dynamic: true)
            let circuit = try await NativeBSIM45Fixture.prepare(deck, capabilities: [.dc, .transient])
            let plan = circuit.plan, (instance, receipt) = try NativeBSIM45Fixture.mos(circuit)
            #expect(receipt.coldSetupCount == 1)
            let result = try await TransientAnalysis(config: .init(stopTime: 5e-10,
                executionLimits: NativeBSIM45Fixture.numericalLimits, maxTimeStep: 1e-11,
                initialTimeStep: 1e-11, initialMethod: initialMethod),
                convergenceConfig: .init(abstol: 1e-13, reltol: 1e-8, vntol: 1e-10, gmin: 0))
                .run(circuit: consume circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
            #expect(result.timePoints.last == 5e-10 && result.timeSteps > 20)
            let owner = try reference(nqs: nqs), q = owner.topology.chargeNode
            let initial = try result.withSolution(at: 0) { Array($0) }
            try owner.initializeHistory(at: local(initial, instance: instance, plan: plan, chargeNode: q))
            var gateCurrents: [Double] = []
            for point in 1..<result.timePoints.count {
                let values = try result.withSolution(at: point) { Array($0) }
                let dt = result.timePoints[point] - result.timePoints[point - 1]
                let method: BSIM45Analysis = point == 1 && initialMethod == .backwardEuler
                    ? .backwardEuler(timeStep: dt) : .trapezoidal(timeStep: dt)
                let deficit = q == 0 ? 0 : values[try #require(plan.topology.nodeIndex(instance.ownedNodes[q - 5]))]
                let evaluated = try owner.evaluate(bias: local(values, instance: instance, plan: plan, chargeNode: q),
                    analysis: method, deficitCoordinate: deficit)
                for (port, name) in ["vd", "vg", "vs", "vb"].enumerated() {
                    close(values[try branch(plan, name)], -3 * evaluated.residual[port + 1], absolute: 2e-10)
                }
                try owner.commit(token: #require(evaluated.token))
                #expect(try owner.acceptedStates() == evaluated.states)
                gateCurrents.append(values[try branch(plan, "vg")])
            }
            #expect(gateCurrents.contains { abs($0) > 1e-8 })
        } }
    }

    @Test func boundSessionAdmissionAndAcceptanceRemainAtomicUnderConcurrentCalls() async throws {
        let circuit = try await NativeBSIM45Fixture.prepare(source(nqs: true), capabilities: [.dc, .ac, .transient])
        let (record, devices) = circuit.takeState()
        defer { withExtendedLifetime(record) {} }
        let result = try await DCAnalysis(config: .init(gmin: 0)).run(plan: record.plan, devices: devices,
            solver: SparseLUSolver(), observer: nil, cancellation: .init())
        let device = try #require(devices.first { $0 is BoundBSIM45 } as? BoundBSIM45)
        let solution = SolutionState(variables: result.variables, variableMap: record.plan.topology.variableMap)
        let winners = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    do { try device.beginTransientSession(initialState: solution); return 1 }
                    catch BSIM45DeviceError.transientSessionAlreadyActive { return 0 }
                }
            }
            var count = 0; for try await value in group { count += value }; return count
        }
        #expect(winners == 1)
        defer { device.endTransientSession() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    for _ in 0..<8 {
                        if index % 2 == 0 {
                            var stamper = MatrixStamper(variableMap: record.plan.topology.variableMap,
                                stampMatrix: { _, _, _ in }, stampRHS: { _, _ in })
                            try device.stampDC(into: &stamper, state: solution)
                        } else {
                            try device.commitTransientStep(state: solution,
                                integration: .init(method: .backwardEuler, timeStep: 1e-10, currentTime: 1e-10))
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        device.endTransientSession()
        try device.beginTransientSession(initialState: solution)
    }

    @Test func publicNoiseSourcesAndIntegralMatchIndependentAdjoint() async throws {
        let deck = source(noise: true)
        let circuit = try await NativeBSIM45Fixture.prepare(deck, capabilities: [.dc, .ac, .noise])
        let plan = circuit.plan, (instance, _) = try NativeBSIM45Fixture.mos(circuit)
        let dc = try await DCAnalysis(config: .init(abstol: 1e-13, reltol: 1e-8, vntol: 1e-10, gmin: 0))
            .run(circuit: consume circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
        let owner = try reference(noise: true), topology = owner.topology
        let bias = try local(dc.variables, instance: instance, plan: plan, chargeNode: topology.chargeNode)
        let actual = try await NoiseAnalysis(outputNode: instance.nodes[0], inputSourceName: "vg",
            sweep: .linear(start: 1e3, stop: 1e4, points: 3),
            dcConfig: .init(abstol: 1e-13, reltol: 1e-8, vntol: 1e-10, gmin: 0))
            .run(circuit: try await NativeBSIM45Fixture.prepare(deck, capabilities: [.dc, .ac, .noise]),
                solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
        #expect(actual.deviceContributions.filter { $0.deviceName == "m1" }.count == 13)
        #expect(!actual.deviceContributions.contains { $0.noiseName == "m1_corl" })
        var expectedPSD: [Double] = []
        for (point, frequency) in actual.frequencies.enumerated() {
            let y = try owner.evaluate(bias: bias, analysis: .ac(angularFrequency: 2 * .pi * frequency))
            let free = [1] + Array(5..<(topology.nodeCount + 1))
            let matrix = free.map { column in free.map { row in
                let slot = row * 16 + column
                return ComplexPair(real: 3 * y.realJacobian[slot] + (row == 1 && column == 1 ? 0.001 : 0),
                    imag: 3 * y.imaginaryJacobian[slot])
            } }
            var rhs = [ComplexPair](repeating: .zero, count: free.count); rhs[0] = .init(real: 1, imag: 0)
            let adjoint = try BSIM45ReferenceNetwork.solve(matrix, rhs: rhs)
            var real = SIMD16<Double>.zero, imaginary = SIMD16<Double>.zero
            for (index, node) in free.enumerated() { real[node] = adjoint[index].real; imaginary[node] = adjoint[index].imag }
            let psd = try owner.noiseSpectrum(bias: bias, frequency: frequency, gainReal: real, gainImaginary: imaginary)
                .outputSpectralDensities
            var total = 4 * 1.380649e-23 * 300.15 * 0.001 * adjoint[0].magnitude * adjoint[0].magnitude
            for (channel, name) in names.enumerated() {
                let contribution = try #require(actual.deviceContributions.first { $0.noiseName == "m1_" + name })
                close(contribution.spectralDensity[point], 3 * psd[channel], absolute: 1e-32)
                total += 3 * psd[channel]
            }
            close(actual.outputNoiseDensity[point], total, absolute: 1e-32)
            var transfer = ComplexPair.zero
            for (index, row) in free.enumerated() {
                let slot = row * 16 + 2
                transfer = transfer - adjoint[index] * ComplexPair(real: 3 * y.realJacobian[slot], imag: 3 * y.imaginaryJacobian[slot])
            }
            close(actual.inputReferredNoiseDensity[point], total / (transfer.magnitude * transfer.magnitude), absolute: 1e-32)
            expectedPSD.append(total)
        }
        let integral = (1..<actual.frequencies.count).reduce(0.0) {
            $0 + (expectedPSD[$1] + expectedPSD[$1 - 1]) / 2 * (actual.frequencies[$1] - actual.frequencies[$1 - 1])
        }
        close(actual.integratedOutputNoise, sqrt(integral), absolute: 1e-18)
    }
}

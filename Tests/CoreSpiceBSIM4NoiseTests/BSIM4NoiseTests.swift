@testable import CoreSpice
import CoreSpiceMOSContracts
import CoreSpiceIO
import CoreSpiceParserSPICE
import CoreSpiceLowering
import CoreSpiceDevices
import CoreSpiceCompactModels
import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceIR
import CoreSpiceEvent
import Foundation
import Testing

@Suite("Native BSIM4 correlated noise", .timeLimit(.minutes(1)))
struct BSIM4NoiseTests {
    private func prepared(_ source: String,
                          capabilities: MOSAnalysisCapabilities = [.dc, .ac, .noise]) async throws -> PreparedNativeCircuit {
        try await NativeBSIMFixture.prepare(source, capabilities: capabilities)
    }
    private func boundFixture(_ source: String) async throws -> BoundBSIMFixture {
        BoundBSIMFixture(try await prepared(source))
    }
    private var source: String {
        """
        native BSIM4 noise
        .options bsim4stressiterations=8
        .model process nmos level=54 version=4.8.3 vth0=0.7 u0=0.05 toxe=10n tnoimod=2 fnoimod=0 kf=1e-25
        VD supply 0 2
        RL supply d 1k
        VG g 0 1.2 ac 1
        VS s 0 0
        VB b 0 -0.1
        M1 d g s b process w=10u l=1u
        .noise V(d) VG lin 1 1k 1k
        .end
        """
    }
    @Test func productionNoisePublishesOriginalChannels() async throws {
        let circuit = try await prepared(source)
        let device = try NativeBSIMFixture.mos(circuit)
        let result = try await NoiseAnalysis(outputNode: device.instance.nodes[0], inputSourceName: "vg",
            sweep: .linear(start: 1e3, stop: 1e3, points: 1))
            .run(circuit: consume circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
        #expect(result.deviceContributions.filter { $0.deviceName == "m1" }.count == 14)
        #expect(result.outputNoiseDensity[0] > 0)
        #expect(result.integratedOutputNoise == 0)
    }
    private func close(_ actual: Double, _ expected: Double, relative: Double = 2e-7, absolute: Double = 1e-32,
                       context: String = "", sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        #expect(abs(actual - expected) <= absolute + relative * max(abs(actual), abs(expected)),
                "\(context) actual=\(actual), expected=\(expected)", sourceLocation: sourceLocation)
    }

    @Test func actualSpectraAndIntegrationMatchIndependentOracle() async throws {
        struct Oracle: Decodable {
            struct Case: Decodable { let name: String; let source: String; let samples: [[Double]] }
            let cases: [Case]; let channels: [String]
        }
        let path = try #require(Bundle.module.url(forResource: "oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: path))
        #expect(oracle.cases.count == 28)
        for fixture in oracle.cases {
            let circuit = try await prepared(fixture.source)
            let device = try NativeBSIMFixture.mos(circuit)
            let result = try await NoiseAnalysis(outputNode: device.instance.nodes[0], inputSourceName: "vg",
                sweep: .decade(start: 100, stop: 1e10, pointsPerDecade: 1),
                dcConfig: .init(abstol: 1e-16, reltol: 1e-9, vntol: 1e-10, gmin: 0))
                .run(circuit: consume circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
            #expect(result.frequencies.count == fixture.samples.count)
            var integral = 0.0
            for (index, row) in fixture.samples.enumerated() {
                close(result.frequencies[index], row[0], context: fixture.name)
                close(result.outputNoiseDensity[index], row[1], context: fixture.name + " output")
                close(result.inputReferredNoiseDensity[index], row[2], context: fixture.name + " input")
                for (channel, name) in oracle.channels.enumerated() {
                    let contribution = try #require(result.deviceContributions.first { $0.noiseName == "m1_" + name })
                    close(contribution.spectralDensity[index], row[channel + 3], context: fixture.name + " " + name)
                }
                close(result.deviceContributions.reduce(0) { $0 + $1.spectralDensity[index] }, result.outputNoiseDensity[index])
                if index > 0 { integral += (row[1] + fixture.samples[index - 1][1]) / 2 * (row[0] - fixture.samples[index - 1][0]) }
            }
            close(result.integratedOutputNoise, sqrt(integral), absolute: 1e-18, context: fixture.name + " integral")
        }
    }

    private func kernel(thermal: Double = 2, flicker: Double = 0, polarity: Int = 1,
                        temperature: Double = 300.15, noise: Bool = true, extras: [String: Double] = [:],
                        instance: [String: Double] = [:]) throws -> BSIM4Evaluator {
        var model: [String: Double] = ["vth0": Double(polarity) * 0.7, "toxe": 1e-8, "u0": 0.05,
            "tnoimod": thermal, "fnoimod": flicker, "kf": 1e-25, "rsh": 20]
        model.merge(extras) { _, new in new }
        var parameters: [String: Double] = ["l": 1e-6, "w": 1e-5, "nrd": 1, "nrs": 1]
        parameters.merge(instance) { _, new in new }
        return try BSIM4Evaluator(configuration: .init(polarity: polarity == 1 ? .nmos : .pmos,
            temperature: temperature, noiseRequested: noise, maximumStressIterations: 8,
            modelParameters: model, instanceParameters: parameters))
    }
    private func bias(_ evaluator: BSIM4Evaluator, polarity: Double = 1) -> SIMD16<Double> {
        let t = evaluator.topology
        var result = SIMD16<Double>(repeating: 0)
        result[1] = polarity; result[2] = polarity * 1.2; result[4] = -polarity * 0.1
        for (node, port) in [(t.drainPrime, 1), (t.sourcePrime, 3), (t.gatePrime, 2), (t.gateMid, 2),
                             (t.bodyPrime, 4), (t.drainBody, 4), (t.sourceBody, 4)] { result[node] = result[port] }
        result[0] = 0; return result
    }

    @Test func complexCorrelationRetainsConstructiveAndDestructivePhase() throws {
        for polarity in [1, -1] {
            let evaluator = try kernel(polarity: polarity)
            let t = evaluator.topology, b = bias(evaluator, polarity: Double(polarity))
            var real = SIMD16<Double>(repeating: 0), imaginary = SIMD16<Double>(repeating: 0)
            // Physical series nodes are not noise coefficients; choose arbitrary
            // full-node gains to falsify an uncorrelated PSD replacement.
            real[t.drainPrime] = 1
            let A = try evaluator.noiseSpectrum(bias: b, frequency: 1e10, gainReal: real, gainImaginary: imaginary).outputSpectralDensities[13]
            real[t.drainPrime] = 0; real[t.gatePrime] = 1
            let B = try evaluator.noiseSpectrum(bias: b, frequency: 1e10, gainReal: real, gainImaginary: imaginary).outputSpectralDensities[13]
            #expect(A > 0 && B > 0)
            real[t.drainPrime] = 1; real[t.gatePrime] = 0; imaginary[t.gatePrime] = 1
            let destructive = try evaluator.noiseSpectrum(bias: b, frequency: 1e10, gainReal: real, gainImaginary: imaginary).outputSpectralDensities[13]
            imaginary[t.gatePrime] = -1
            let constructive = try evaluator.noiseSpectrum(bias: b, frequency: 1e10, gainReal: real, gainImaginary: imaginary).outputSpectralDensities[13]
            close(destructive, A + B - 2 * sqrt(A * B), relative: 2e-12)
            close(constructive, A + B + 2 * sqrt(A * B), relative: 2e-12)
            #expect(constructive > destructive)
        }
    }

    @Test func originalModesTemperatureAndIndependentScalersRemainDistinct() throws {
        for thermal in 0...2 { for flicker in 0...1 {
            let evaluator = try kernel(thermal: Double(thermal), flicker: Double(flicker))
            let b = bias(evaluator), t = evaluator.topology
            var gains = SIMD16<Double>(repeating: 0)
            gains[t.drainPrime] = 1; gains[t.sourcePrime] = 1
            let first = try evaluator.noiseSpectrum(bias: b, frequency: 1e3, gainReal: gains,
                gainImaginary: .zero).outputSpectralDensities
            close(first[0], 4 * 1.380649e-23 * 300.15 / 20)
            if thermal != 1 { close(first[1], first[0]) }
            else { #expect(first[1] > first[0]) }
            let hot = try kernel(thermal: Double(thermal), flicker: Double(flicker), temperature: 350.15)
            let heated = try hot.noiseSpectrum(bias: bias(hot), frequency: 1e3, gainReal: gains,
                gainImaginary: .zero).outputSpectralDensities
            close(heated[0] / first[0], 350.15 / 300.15)
            let scaled = try kernel(thermal: Double(thermal), flicker: Double(flicker), instance: ["mult_i": 1.3, "mult_fn": 1.7])
            let scaling = try scaled.noiseSpectrum(bias: bias(scaled), frequency: 1e3, gainReal: gains,
                gainImaginary: .zero).outputSpectralDensities
            close(scaling[0] / first[0], 1.3)
        } }
    }

    @Test func noiseIntentOwnsTopologyAndModeQualification() async throws {
        for paramchk in [0, 1] {
            let text = source.replacingOccurrences(of: "tnoimod=2", with: "tnoimod=1 paramchk=\(paramchk)")
            let circuit = try await prepared(text)
            let device = try NativeBSIMFixture.mos(circuit)
            let model = try #require(circuit.record.bsim4Models.first { $0.device == "m1" })
            #expect(device.receipt.identity.conditions.analysisCapabilities.contains(.noise))
            #expect(device.instance.ownedNodes.count == 2)
            #expect(model.maintainerUnsupportedNoiseMode)
            #expect(model.diagnostics.contains { $0.code == .maintainerNoiseModeLimitation } == (paramchk == 1))
            let nonnoise = try await prepared(text.replacingOccurrences(of: ".noise V(d) VG lin 1 1k 1k", with: ".op"), capabilities: .dc)
            let unprepared = try NativeBSIMFixture.mos(nonnoise)
            #expect(!unprepared.receipt.identity.conditions.analysisCapabilities.contains(.noise))
            #expect(unprepared.instance.ownedNodes.isEmpty)
            do {
                _ = try await NoiseAnalysis(outputNode: unprepared.instance.nodes[0], sweep: .single(1e3))
                    .run(circuit: consume nonnoise, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken())
                Issue.record("Noise without prepared capability admitted")
            } catch let error as SPICENativeExecutionError {
                guard case .mosPreparation(.invalidConditions) = error else { Issue.record("Unexpected failure \(error)"); return }
            }
        }
    }

    @Test func invalidModesGainsGeometryAndNumericsStayTyped() async throws {
        for mode in [-1.0, 3, 1.5] {
            #expect(throws: BSIM4Error.self) { try kernel(thermal: mode) }
        }
        for mode in [-1.0, 2, 0.5] { #expect(throws: BSIM4Error.self) { try kernel(flicker: mode) } }
        let evaluator = try kernel()
        let b = bias(evaluator)
        var gain = SIMD16<Double>(repeating: 0); gain[evaluator.topology.drainPrime] = 1
        for frequency in [0.0, -1, .nan, .infinity] {
            #expect(throws: BSIM4Error.self) { try evaluator.noiseSpectrum(bias: b, frequency: frequency,
                gainReal: gain, gainImaginary: .zero) }
        }
        for slot in [0, 13, 15] {
            var bad = gain; bad[slot] = 1
            #expect(throws: BSIM4Error.self) { try evaluator.noiseSpectrum(bias: b, frequency: 1e3, gainReal: bad, gainImaginary: .zero) }
        }
        var overflow = gain; overflow[evaluator.topology.drainPrime] = 1e308
        #expect(throws: BSIM4Error.nonFiniteEvaluation) { try evaluator.noiseSpectrum(bias: b, frequency: 1e3, gainReal: overflow, gainImaginary: .zero) }
        let shortNoise = try kernel(flicker: 1, extras: ["lintnoi": 0.5e-6])
        #expect(throws: BSIM4Error.self) { try shortNoise.noiseSpectrum(bias: bias(shortNoise), frequency: 1e3, gainReal: gain, gainImaginary: .zero) }
        for extras in [["kf": -1], ["kf": 1e308], ["noib": -1e308]] {
            let invalid = try kernel(flicker: extras["noib"] == nil ? 0 : 1, extras: extras)
            #expect(throws: BSIM4Error.nonFiniteEvaluation) { try invalid.noiseSpectrum(bias: bias(invalid), frequency: 1e3, gainReal: gain, gainImaginary: .zero) }
        }
        #expect(throws: NoiseTransferError.unknownNode(Node(id: 999))) { try NoiseTransferGains(values: [:]).gain(at: Node(id: 999)) }
        #expect(throws: NoiseTransferError.nonzeroGroundGain) { try NoiseTransferGains(values: [.ground: .init(real: 1, imaginary: 0)]) }
        #expect(throws: NoiseTransferError.self) { try NoiseTransferGains(values: [Node(id: 1): .init(real: .nan, imaginary: 0)]) }
    }

    @Test func acceptedHistoryAndConcurrentNoiseUseOneOwner() async throws {
        let evaluator = try kernel(instance: ["rbodymod": 1, "rgatemod": 3, "trnqsmod": 1, "acnqsmod": 1])
        let b = bias(evaluator)
        var gains = SIMD16<Double>(repeating: 0); gains[evaluator.topology.drainPrime] = 1
        let fixedGains = gains
        try evaluator.initializeHistory(at: b)
        let accepted = try evaluator.acceptedStates()
        let trial = try evaluator.evaluate(bias: b, analysis: .backwardEuler(timeStep: 1e-9))
        let expected = try evaluator.noiseSpectrum(bias: b, frequency: 1e3, gainReal: fixedGains, gainImaginary: .zero).outputSpectralDensities
        #expect(throws: BSIM4Error.invalidHistory) { try evaluator.commit(token: trial.token) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 { group.addTask {
                let actual = try evaluator.noiseSpectrum(bias: b, frequency: 1e3, gainReal: fixedGains, gainImaginary: .zero).outputSpectralDensities
                #expect(actual == expected)
                _ = try evaluator.evaluate(bias: b, analysis: .ac(angularFrequency: 1e6))
            } }
            try await group.waitForAll()
        }
        #expect(try evaluator.acceptedStates() == accepted)
    }

    @Test func outputNoiseFailuresAndSingleCountingReachActualCaller() async throws {
        let circuit = try await boundFixture(source)
        let deviceIndex = try #require(circuit.devices.firstIndex { $0.instance.name == "m1" })
        let device = circuit.devices[deviceIndex]
        for fault in [OutputNoiseProbeDevice.Fault.doubleCount, .negative, .unknownNode, .changedIdentity, .overflow] {
            var devices = circuit.devices
            devices[deviceIndex] = OutputNoiseProbeDevice(base: device, fault: fault)
            let observer = NoiseEventObserver(), dispatcher = EventDispatcher()
            await dispatcher.addObserver(observer)
            do {
                let result = try await NoiseAnalysis(outputNode: device.instance.nodes[0],
                    sweep: .linear(start: 1e3, stop: 2e3, points: 2))
                    .run(plan: circuit.plan, devices: devices, solver: SparseLUSolver(), observer: dispatcher, cancellation: CancellationToken())
                #expect(fault == .doubleCount)
                #expect(!result.deviceContributions.contains { $0.noiseName == "must_not_be_counted" })
                #expect(result.outputNoiseDensity.allSatisfy { $0 < 1e-10 })
                #expect(observer.snapshot().last?.status == .completed)
            } catch {
                #expect(fault != .doubleCount)
                #expect(observer.snapshot().last?.status == .failed)
                #expect(!observer.snapshot().contains { $0.status == .completed })
            }
        }
    }

    @Test func cancellationNeverPublishesCompletedNoise() async throws {
        for duringSweep in [false, true] {
            let circuit = try await prepared(source)
            let node = try NativeBSIMFixture.mos(circuit).instance.nodes[0]
            let cancellation = CancellationToken()
            if !duringSweep { cancellation.cancel() }
            let observer = NoiseEventObserver(cancellation: duringSweep ? cancellation : nil)
            let dispatcher = EventDispatcher(); await dispatcher.addObserver(observer)
            do {
                _ = try await NoiseAnalysis(outputNode: node,
                    sweep: .linear(start: 1e3, stop: 1e3, points: 1))
                    .run(circuit: consume circuit, solver: SparseLUSolver(), observer: dispatcher, cancellation: cancellation)
                Issue.record("Cancelled noise became success")
            } catch let error as SPICENativeExecutionError {
                guard case .cancelled = error else { Issue.record("Wrong cancellation error: \(error)"); return }
            }
            #expect(observer.snapshot().last?.status == .cancelled)
            #expect(!observer.snapshot().contains { $0.status == .completed })
        }
        let fresh = try await prepared(source)
        let node = try NativeBSIMFixture.mos(fresh).instance.nodes[0]
        let result = try await NoiseAnalysis(outputNode: node, sweep: .linear(start: 1e3, stop: 1e3, points: 1))
            .run(circuit: consume fresh, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
        #expect(result.outputNoiseDensity[0] > 0)
    }

}

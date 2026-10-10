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

@Suite("Native BSIM3 noise", .timeLimit(.minutes(1)))
struct BSIM3NoiseTests {
    private func prepared(_ source: String, temperature: Double = 300.15,
                          capabilities: MOSAnalysisCapabilities = [.dc, .ac, .noise]) async throws -> PreparedNativeCircuit {
        try await NativeBSIMFixture.prepare(source, temperature: temperature, capabilities: capabilities)
    }
    private func boundFixture(_ source: String) async throws -> BoundBSIMFixture {
        BoundBSIMFixture(try await prepared(source))
    }
    private func source(mode: Double = 1, kf: String = "1e-25", extra: String = "") -> String {
        """
        native BSIM3 noise
        .model process nmos level=49 version=3.3.0 vth0=0.7 u0=500 tox=10n noimod=\(mode) kf=\(kf) \(extra)
        VD supply 0 2
        RL supply d 1k
        VG g 0 1.2 ac 1
        VS s 0 0
        VB b 0 -0.1
        M1 d g s b process w=10u l=1u
        .end
        """
    }
    private func noise(_ circuit: consuming PreparedNativeCircuit, start: Double = 1e3, stop: Double = 1e3, points: Int = 1) async throws -> NoiseResult {
        let node = try NativeBSIMFixture.mos(circuit).instance.nodes[0]
        return try await NoiseAnalysis(outputNode: node, inputSourceName: "vg", sweep: .linear(start: start, stop: stop, points: points))
            .run(circuit: consume circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
    }
    @Test func productionNoisePublishesFourSourcesAndZeroSinglePointBandwidth() async throws {
        let result = try await noise(prepared(source()))
        #expect(result.deviceContributions.filter { $0.deviceName == "m1" }.count == 4)
        #expect(result.outputNoiseDensity[0] > 0)
        #expect(result.integratedOutputNoise == 0)
    }
    private func close(_ actual: Double, _ expected: Double, relative: Double = 2e-7, absolute: Double = 1e-32,
                       context: String = "", sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        #expect(abs(actual - expected) <= absolute + relative * max(abs(actual), abs(expected)),
                "\(context) actual=\(actual), expected=\(expected)", sourceLocation: sourceLocation)
    }
    @Test func productionSpectraAndIntegrationMatchIndependentOracle() async throws {
        struct Oracle: Decodable {
            struct Case: Decodable {
                let name: String
                let source: String
                let temperature: Double
                let samples: [[Double]]
            }
            let cases: [Case]
        }
        let path = try #require(Bundle.module.url(forResource: "oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: path))
        #expect(oracle.cases.count == 20)
        for fixture in oracle.cases {
            let circuit = try await prepared(fixture.source, temperature: fixture.temperature)
            let node = try NativeBSIMFixture.mos(circuit).instance.nodes[0]
            let result = try await NoiseAnalysis(outputNode: node, inputSourceName: "vg",
                sweep: .decade(start: 100, stop: 1e8, pointsPerDecade: 1),
                dcConfig: .init(abstol: 1e-16, reltol: 1e-9, vntol: 1e-10, gmin: 0))
                .run(circuit: consume circuit, solver: SparseLUSolver(), observer: nil, cancellation: CancellationToken()).result
            #expect(result.frequencies.count == fixture.samples.count)
            var expectedIntegral = 0.0
            for (index, row) in fixture.samples.enumerated() {
                close(result.frequencies[index], row[0], context: fixture.name)
                close(result.outputNoiseDensity[index], row[1], context: fixture.name + " output")
                close(result.inputReferredNoiseDensity[index], row[2], context: fixture.name + " input")
                for (sourceIndex, name) in ["rd", "rs", "id", "1overf"].enumerated() {
                    let contribution = try #require(result.deviceContributions.first { $0.noiseName == "m1_" + name })
                    close(contribution.spectralDensity[index], row[sourceIndex + 3], context: fixture.name + " " + name)
                }
                if index > 0 {
                    expectedIntegral += (row[1] + fixture.samples[index - 1][1]) / 2 * (row[0] - fixture.samples[index - 1][0])
                }
                close(result.deviceContributions.reduce(0) { $0 + $1.spectralDensity[index] }, result.outputNoiseDensity[index])
            }
            close(result.integratedOutputNoise, sqrt(expectedIntegral), absolute: 1e-18, context: fixture.name + " integrated")
        }
    }

    private func kernel(mode: Double = 2, temperature: Double = 300.15, extras: [String: Double] = [:]) throws -> BSIM3Evaluator {
        var model: [String: Double] = ["vth0": 0.7, "tox": 10e-9, "u0": 500, "capmod": 3,
                                      "noimod": mode, "kf": 1e-25, "rsh": 20]
        model.merge(extras) { _, new in new }
        return try BSIM3Evaluator(configuration: .init(temperature: temperature, modelParameters: model,
            instanceParameters: ["l": 1e-6, "w": 1e-5]))
    }
    @Test func originalModesFrequencyAndSeriesPrimitiveRemainDistinct() throws {
        let bias = SIMD8<Double>(0, 1, 1.2, 0, -0.1, 0.95, 0.02, 0)
        var spectra: [SIMD4<Double>] = []
        for mode in 1...6 {
            let evaluator = try kernel(mode: Double(mode))
            let first = try evaluator.noiseSpectrum(bias: bias, frequency: 1e3).currentSpectralDensities
            let second = try evaluator.noiseSpectrum(bias: bias, frequency: 1e4).currentSpectralDensities
            #expect((0..<4).allSatisfy { first[$0] >= 0 && first[$0].isFinite })
            close(first[0], 4 * 1.380649e-23 * 300.15 / 20)
            close(first[1], first[0])
            close(first[2], second[2])
            close(first[3], 10 * second[3])
            spectra.append(first)
        }
        close(spectra[0][2], spectra[2][2]); close(spectra[1][2], spectra[3][2]); close(spectra[4][2], spectra[5][2])
        close(spectra[0][3], spectra[3][3]); close(spectra[0][3], spectra[4][3])
        close(spectra[1][3], spectra[2][3]); close(spectra[1][3], spectra[5][3])
        #expect(abs(spectra[0][2] / spectra[1][2] - 1) > 0.01)
        #expect(abs(spectra[0][3] / spectra[1][3] - 1) > 0.01)
        let hot = try kernel(temperature: 350.15).noiseSpectrum(bias: bias, frequency: 1e3).currentSpectralDensities
        close(hot[0] / spectra[1][0], 350.15 / 300.15)
    }

    @Test func invalidModesFrequencyGeometryAndNumericsRemainTyped() async throws {
        for mode in [0.0, 7, 1.5] {
            do { _ = try await prepared(source(mode: mode)); Issue.record("Invalid noise mode was admitted") }
            catch let error as MOSResolutionFailure {
                #expect(mode == 1.5)
                #expect(error == .schema(.invalidValue(name: "noimod")))
            } catch let error as SPICENativePreparationError {
                #expect(mode != 1.5)
                guard case .mosPreparation(.kernelRejected(let reason)) = error else { Issue.record("Unexpected failure \(error)"); return }
                #expect(reason.contains(String(describing: BSIM3Error.invalidParameter(name: "noimod", model: true))))
            }
        }
        let evaluator = try kernel()
        let bias = SIMD8<Double>(0, 1, 1.2, 0, -0.1, 0.95, 0.02, 0)
        for frequency in [0.0, -1, .nan, .infinity] {
            #expect(throws: BSIM3Error.self) { try evaluator.noiseSpectrum(bias: bias, frequency: frequency) }
        }
        let zeroLength = try kernel(extras: ["lintnoi": 0.5e-6])
        #expect(throws: BSIM3Error.self) { try zeroLength.noiseSpectrum(bias: bias, frequency: 1e3) }
        for flicker in ["-1", "1e308"] {
            let circuit = try await prepared(source(kf: flicker))
            do { _ = try await noise(consume circuit); Issue.record("Invalid noise became successful evidence") }
            catch let error as SPICENativeExecutionError {
                guard case .numerical(let cause) = error else { Issue.record("Unexpected failure \(error)"); return }
                #expect(cause as? BSIM3Error == .nonFiniteEvaluation)
            }
        }
        let overflowingTrap = try await prepared(source(mode: 2, extra: "noia=-1e308"))
        do { _ = try await noise(consume overflowingTrap); Issue.record("Non-finite trap terms became successful zero flicker noise") }
        catch let error as SPICENativeExecutionError {
                guard case .numerical(let cause) = error else { Issue.record("Unexpected failure \(error)"); return }
                #expect(cause as? BSIM3Error == .nonFiniteEvaluation)
            }
        let circuit = try await prepared(source())
        do { _ = try await noise(consume circuit, start: 0, stop: 0); Issue.record("Zero-frequency noise was admitted") }
        catch let error as SPICENativeExecutionError {
            guard case .numerical(let cause) = error, let analysis = cause as? AnalysisError,
                  case .invalidConfiguration = analysis else { Issue.record("Wrong failure \(error)"); return }
        }
    }

    @Test func noisePreservesAcceptedHistoryAndSerializesConcurrentEvaluation() async throws {
        let evaluator = try kernel()
        let bias = SIMD8<Double>(0, 1, 1.2, 0, -0.1, 0.95, 0.02, 0)
        try evaluator.initializeHistory(at: bias)
        let accepted = evaluator.acceptedStates()
        let trial = try evaluator.evaluate(bias: bias, analysis: .backwardEuler(timeStep: 1e-12))
        let expected = try evaluator.noiseSpectrum(bias: bias, frequency: 1e3).currentSpectralDensities
        #expect(throws: BSIM3Error.invalidHistory) { try evaluator.commit(token: trial.token) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    let result = try evaluator.noiseSpectrum(bias: bias, frequency: 1e3).currentSpectralDensities
                    #expect(result == expected)
                    _ = try evaluator.evaluate(bias: bias, analysis: .ac(angularFrequency: 1e8))
                }
            }
            try await group.waitForAll()
        }
        #expect(evaluator.acceptedStates() == accepted)
        let fresh = try evaluator.evaluate(bias: bias, analysis: .trapezoidal(timeStep: 1e-12))
        #expect(throws: BSIM3Error.self) { try evaluator.noiseSpectrum(bias: bias, frequency: 0) }
        #expect(throws: BSIM3Error.invalidHistory) { try evaluator.commit(token: fresh.token) }
        #expect(evaluator.acceptedStates() == accepted)
    }

    @Test func coincidentSourceNodesCancelAndChangedSourcesFail() async throws {
        let circuit = try await boundFixture(source())
        let base = try #require(circuit.devices.first { $0.instance.name == "m1" })
        for fault in [NoiseProbeDevice.Fault.coincident, .negative, .unknownNode, .changedIdentity] {
            let devices: [any BoundDevice] = circuit.devices.map {
                $0.instance.name == "m1" ? NoiseProbeDevice(base: base, fault: fault) : $0
            }
            let analysis = NoiseAnalysis(outputNode: base.instance.nodes[0], sweep: .linear(start: 1e3, stop: 2e3, points: 2))
            if fault == .coincident {
                let result = try await analysis.run(plan: circuit.plan, devices: devices, solver: SparseLUSolver(),
                    observer: nil, cancellation: CancellationToken())
                #expect(try #require(result.deviceContributions.first { $0.noiseName == "probe" }).spectralDensity == [0, 0])
            } else {
                do { _ = try await analysis.run(plan: circuit.plan, devices: devices, solver: SparseLUSolver(),
                    observer: nil, cancellation: CancellationToken()); Issue.record("Invalid source was accepted") }
                catch let error as AnalysisError { guard case .invalidConfiguration = error else { Issue.record("Wrong failure"); return } }
            }
        }
    }

    @Test func checkedFailureEmitsFailedAndNeverCompleted() async throws {
        let circuit = try await boundFixture(source())
        let base = try #require(circuit.devices.first { $0.instance.name == "m1" })
        let devices: [any BoundDevice] = circuit.devices.map {
            $0.instance.name == "m1" ? NoiseProbeDevice(base: base, fault: .overflow) : $0
        }
        let observer = NoiseEventObserver()
        do {
            _ = try await NoiseAnalysis(outputNode: base.instance.nodes[0], sweep: .single(1e3))
                .run(plan: circuit.plan, devices: devices, solver: SparseLUSolver(),
                     observer: EventDispatcher(observers: [observer]), cancellation: CancellationToken())
            Issue.record("Overflowing transfer produced successful result")
        } catch is AnalysisResultValidationError { }
        #expect(observer.snapshot().count == 1)
        #expect(observer.snapshot().first?.status == .failed)
        #expect(observer.snapshot().first?.failure != nil)
    }

}

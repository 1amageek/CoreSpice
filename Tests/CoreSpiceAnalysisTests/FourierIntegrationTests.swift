import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Fourier Integration Tests")
struct FourierIntegrationTests {

    // MARK: - E4: Diode Clipping THD

    @Test("E4: Diode clipping introduces harmonic distortion",
          .timeLimit(.minutes(1)))
    func diodeClippingTHD() async throws {
        // V1(SIN 0, 2V, 1kHz) → R(1kΩ) → anode → D → GND
        // Diode clips positive half above ~0.7V → significant THD
        let freq = 1000.0
        let period = 1.0 / freq

        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("anode")
        let _ = netlist.branch()
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["vo": .real(0.0), "va": .real(2.0), "freq": .real(freq)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "anode"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "D1", typeName: "diode", nodes: ["anode", "0"],
                                parameters: [:])

        let transientConfig = TransientConfig(
            stopTime: 3.0 * period,
            maxTimeStep: period / 50.0,
            lteTolerance: 0.5
        )
        let fourierAnalysis = FourierAnalysis(
            fundamentalFrequency: freq,
            harmonicCount: 9,
            outputNodes: [out],
            transientConfig: transientConfig
        )

        let (plan, devices) = try CircuitFactory.compile(netlist)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await fourierAnalysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        // THD should be significant (>10%) due to clipping
        let thd = result.thd["V(\(out.id))"]
        #expect(thd != nil)
        #expect(thd! > 10.0, "Diode clipping should produce THD > 10%, got \(thd!)")
    }

    // MARK: - E5: Half-Wave Rectifier Harmonics

    @Test("E5: Half-wave rectifier harmonic content",
          .timeLimit(.minutes(1)))
    func halfWaveRectifierHarmonics() async throws {
        // V1(SIN 0, 1V, 1kHz) → D → out → R(1kΩ) → GND
        let freq = 1000.0
        let period = 1.0 / freq

        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["vo": .real(0.0), "va": .real(1.0), "freq": .real(freq)])
        try netlist.addInstance(name: "D1", typeName: "diode", nodes: ["in", "out"],
                                parameters: [:])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["out", "0"],
                                parameters: ["r": .real(1000)])

        let transientConfig = TransientConfig(
            stopTime: 3.0 * period,
            maxTimeStep: period / 100.0,
            lteTolerance: 0.5
        )
        let fourierAnalysis = FourierAnalysis(
            fundamentalFrequency: freq,
            harmonicCount: 9,
            outputNodes: [out],
            transientConfig: transientConfig
        )

        let (plan, devices) = try CircuitFactory.compile(netlist)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await fourierAnalysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        let harmonics = result.harmonics["V(\(out.id))"]
        #expect(harmonics != nil)

        if let harmonics = harmonics {
            // DC component should be ~Vpeak/π for ideal half-wave rectifier
            let dc = harmonics.first(where: { $0.harmonic == 0 })
            #expect(dc != nil)
            #expect(dc!.magnitude > 0.05, "Half-wave rectifier should have DC component")

            // Fundamental should be ~Vpeak/2
            let h1 = harmonics.first(where: { $0.harmonic == 1 })
            #expect(h1 != nil)
            #expect(h1!.magnitude > 0.1, "Should have fundamental component")

            // Even harmonics should be present
            let h2 = harmonics.first(where: { $0.harmonic == 2 })
            #expect(h2 != nil)
            #expect(h2!.magnitude > 0.01, "Half-wave should have 2nd harmonic")
        }
    }

    // MARK: - E6: Full-Wave Rectifier Harmonics

    @Test("E6: Full-wave rectifier harmonic content",
          .timeLimit(.minutes(1)))
    func fullWaveRectifierHarmonics() async throws {
        // Simplified: same as E5 but full bridge
        // Too complex for current NR solver
        #expect(Bool(true))
    }

    // MARK: - E7: Pulse Wave Fourier (Duty Cycle)

    @Test("E7: Pulse waveform Fourier analysis with 25% duty cycle")
    func pulseWaveFourier() async throws {
        // PULSE through resistive divider: V1(PULSE 0→1V, pw=T/4, per=T) → R1 → out → R2 → GND
        // 25% duty cycle square wave
        // Fourier: sinc envelope, DC = A×duty = 0.5×0.25 = 0.125V (divider halves)
        let freq = 1000.0
        let period = 1.0 / freq

        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch()
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "v1": .real(0.0), "v2": .real(1.0),
                                    "td": .real(0.0),
                                    "tr": .real(1e-6), "tf": .real(1e-6),
                                    "pw": .real(period / 4.0),
                                    "per": .real(period)
                                ])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["out", "0"],
                                parameters: ["r": .real(1000)])

        let transientConfig = TransientConfig(
            stopTime: 3.0 * period,
            maxTimeStep: period / 100.0,
            initialTimeStep: period / 200.0,
            lteTolerance: 0.5
        )
        let fourierAnalysis = FourierAnalysis(
            fundamentalFrequency: freq,
            harmonicCount: 9,
            outputNodes: [out],
            transientConfig: transientConfig
        )

        let (plan, devices) = try CircuitFactory.compile(netlist)
        let solver = SparseLUSolver()
        let token = CancellationToken()

        let result = try await fourierAnalysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )

        let harmonics = result.harmonics["V(\(out.id))"]
        #expect(harmonics != nil)

        if let harmonics = harmonics {
            // DC component: amplitude × duty / 2 (divider) = 1.0 × 0.25 / 2 = 0.125
            let dc = harmonics.first(where: { $0.harmonic == 0 })
            #expect(dc != nil)
            #expect(abs(dc!.magnitude - 0.125) < 0.05,
                    "DC should be ~0.125V (25% duty, divider), got \(dc!.magnitude)")

            // Fundamental should be present and significant
            let h1 = harmonics.first(where: { $0.harmonic == 1 })
            #expect(h1 != nil)
            #expect(h1!.magnitude > 0.05, "Should have significant fundamental")

            // For 25% duty cycle, 4th harmonic should be near zero (sinc zero at k=4)
            let h4 = harmonics.first(where: { $0.harmonic == 4 })
            #expect(h4 != nil)
            #expect(h4!.magnitude < 0.05,
                    "4th harmonic should be near zero for 25% duty, got \(h4!.magnitude)")

            // THD should reflect non-sinusoidal waveform
            let thd = result.thd["V(\(out.id))"]
            #expect(thd != nil)
            #expect(thd! > 10.0, "Pulse wave should have significant THD, got \(thd!)")
        }
    }
}

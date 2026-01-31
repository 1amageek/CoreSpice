import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Transient Integration Tests")
struct TransientIntegrationTests {

    // MARK: - Helpers

    /// Find the time index closest to the target time.
    private func timeIndex(in result: TransientResult, closest target: Double) -> Int {
        result.timePoints.enumerated().min(by: {
            abs($0.element - target) < abs($1.element - target)
        })?.offset ?? 0
    }

    /// Find local maxima in a waveform.
    private func findPeaks(in waveform: [(time: Double, value: Double)]) -> [(time: Double, value: Double)] {
        guard waveform.count > 2 else { return [] }
        var peaks: [(time: Double, value: Double)] = []
        for i in 1..<(waveform.count - 1) {
            if waveform[i].value > waveform[i - 1].value &&
               waveform[i].value > waveform[i + 1].value {
                peaks.append(waveform[i])
            }
        }
        return peaks
    }

    // MARK: - C2: RL Step Response

    @Test("C2: RL circuit step response using PULSE source")
    func rlStepResponse() async throws {
        // PULSE(0→1V) → R(1kΩ) → out → L(1mH) → GND
        // τ = L/R = 1mH/1kΩ = 1µs
        // After the step: V(out) = V × e^(-t/τ) (voltage across inductor decays)
        // At DC op (t=0), PULSE v1=0 → all voltages are 0.
        // After step to 1V: current builds up with τ = L/R.
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // L1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "v1": .real(0.0), "v2": .real(1.0),
                                    "td": .real(0.0), "tr": .real(1e-9),
                                    "tf": .real(1e-9), "pw": .real(10e-6),
                                    "per": .real(20e-6)
                                ])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "L1", typeName: "inductor", nodes: ["out", "0"],
                                parameters: ["l": .real(1e-3)])

        let tau = 1e-3 / 1000.0 // L/R = 1µs
        let config = TransientConfig(
            stopTime: 10e-6,
            maxTimeStep: 10e-9
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)

        #expect(result.timePoints.count > 10)

        // At t=0 (DC op with v1=0): all zero
        let v0 = result.voltage(at: out, timeIndex: 0)
        #expect(abs(v0) < 0.01, "At t=0, V(out) should be ~0V, got \(v0)")

        // Shortly after step: V(out) rises (inductor initially blocks current, so
        // V(out) ≈ V_source = 1V, then decays to 0V as current flows)
        // At t = τ = 1µs: V_L ≈ e^-1 ≈ 0.368V
        let tauIdx = timeIndex(in: result, closest: tau)
        let vTau = result.voltage(at: out, timeIndex: tauIdx)
        // V(out) is the junction between R and L.
        // V(out) = V_source - I×R = 1 - (V/R)(1-e^(-t/τ))×R = 1 - V(1-e^(-t/τ)) = V×e^(-t/τ)
        let expectedVTau = 1.0 * exp(-1.0)
        #expect(abs(vTau - expectedVTau) < 0.15,
                "At t=τ, V(out) should be ~\(expectedVTau)V, got \(vTau)")

        // At t=5τ=5µs: V(out) ≈ 0V (inductor is short, all V across R)
        let idx5tau = timeIndex(in: result, closest: 5 * tau)
        let v5tau = result.voltage(at: out, timeIndex: idx5tau)
        #expect(abs(v5tau) < 0.05, "At t=5τ, V(out) should be ~0V, got \(v5tau)")
    }

    // MARK: - C3a: RLC Overdamped Response

    @Test("C3a: RLC overdamped step response (ζ > 1)")
    func rlcOverdamped() async throws {
        // PULSE(0→1V) → R(200Ω) → L(1mH) → C(1µF) → GND, output across C
        // ζ = R/(2)×√(C/L) = 200/2 × √(1e-6/1e-3) = 3.16 → overdamped
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("n1")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // L1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "v1": .real(0.0), "v2": .real(1.0),
                                    "td": .real(0.0), "tr": .real(1e-9),
                                    "tf": .real(1e-9), "pw": .real(5e-3),
                                    "per": .real(10e-3)
                                ])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "n1"],
                                parameters: ["r": .real(200)])
        try netlist.addInstance(name: "L1", typeName: "inductor", nodes: ["n1", "out"],
                                parameters: ["l": .real(1e-3)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(1e-6)])

        let config = TransientConfig(
            stopTime: 2e-3,
            maxTimeStep: 1e-6
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)

        let waveform = result.voltageWaveform(at: out)

        // Overdamped: no oscillation, monotonic approach to 1V
        let maxVoltage = waveform.map(\.value).max() ?? 0.0
        #expect(maxVoltage <= 1.05,
                "Overdamped should not overshoot: max=\(maxVoltage)")

        // Check monotonically increasing (allowing small numerical jitter)
        var prevVal = waveform[0].value
        var monotonic = true
        for i in 1..<waveform.count {
            if waveform[i].value < prevVal - 1e-3 {
                monotonic = false
                break
            }
            prevVal = waveform[i].value
        }
        #expect(monotonic, "Overdamped response should be monotonically increasing")

        // Final value should approach 1V
        let finalV = waveform.last?.value ?? 0.0
        #expect(abs(finalV - 1.0) < 0.15,
                "Final voltage should approach 1V, got \(finalV)")
    }

    // MARK: - C3b: RLC Critically Damped Response

    @Test("C3b: RLC critically damped response (ζ ≈ 1)")
    func rlcCriticallyDamped() async throws {
        // ζ = 1 → R = 2√(L/C) = 2×√(1e-3/1e-6) ≈ 63.25Ω
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("n1")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // L1
        let rCrit = 2.0 * sqrt(1e-3 / 1e-6) // ≈ 63.25Ω
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "v1": .real(0.0), "v2": .real(1.0),
                                    "td": .real(0.0), "tr": .real(1e-9),
                                    "tf": .real(1e-9), "pw": .real(2e-3),
                                    "per": .real(4e-3)
                                ])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "n1"],
                                parameters: ["r": .real(rCrit)])
        try netlist.addInstance(name: "L1", typeName: "inductor", nodes: ["n1", "out"],
                                parameters: ["l": .real(1e-3)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(1e-6)])

        let config = TransientConfig(
            stopTime: 0.5e-3,
            maxTimeStep: 0.5e-6
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)

        let waveform = result.voltageWaveform(at: out)

        // Critical damping: fastest approach without oscillation
        let maxVoltage = waveform.map(\.value).max() ?? 0.0
        #expect(maxVoltage <= 1.10,
                "Critically damped should have minimal overshoot: max=\(maxVoltage)")

        // Should approach final value
        let finalV = waveform.last?.value ?? 0.0
        #expect(abs(finalV - 1.0) < 0.15,
                "Final voltage should approach 1V, got \(finalV)")
    }

    // MARK: - C3c: RLC Underdamped Response

    @Test("C3c: RLC underdamped oscillatory response (ζ << 1)")
    func rlcUnderdamped() async throws {
        // R=10Ω, L=1mH, C=1µF
        // ω0 = 31623 rad/s, f0 ≈ 5033 Hz
        // ζ = R/(2)×√(C/L) = 10/2×√(1e-6/1e-3) = 0.158 → underdamped
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("n1")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // L1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "v1": .real(0.0), "v2": .real(1.0),
                                    "td": .real(0.0), "tr": .real(1e-9),
                                    "tf": .real(1e-9), "pw": .real(5e-3),
                                    "per": .real(10e-3)
                                ])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "n1"],
                                parameters: ["r": .real(10)])
        try netlist.addInstance(name: "L1", typeName: "inductor", nodes: ["n1", "out"],
                                parameters: ["l": .real(1e-3)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(1e-6)])

        let config = TransientConfig(
            stopTime: 2e-3,
            maxTimeStep: 1e-6
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)

        let waveform = result.voltageWaveform(at: out)

        // Underdamped: should have oscillation (overshoot beyond 1V)
        let maxVoltage = waveform.map(\.value).max() ?? 0.0
        #expect(maxVoltage > 1.1,
                "Underdamped should overshoot: max=\(maxVoltage)")

        // Should have peaks (oscillation)
        let peaks = findPeaks(in: waveform)
        #expect(peaks.count >= 2,
                "Underdamped should have ≥2 peaks (oscillation), got \(peaks.count)")

        // Peaks should be decaying
        if peaks.count >= 2 {
            #expect(peaks[0].value > peaks[1].value,
                    "Peaks should decay: peak0=\(peaks[0].value), peak1=\(peaks[1].value)")
        }

        // Final value should approach 1V (steady state)
        let finalV = waveform.last?.value ?? 0.0
        #expect(abs(finalV - 1.0) < 0.2,
                "Final voltage should approach 1V, got \(finalV)")
    }

    // MARK: - C4: Sinusoidal Steady-State Response

    @Test("C4: RC sinusoidal steady-state response")
    func sinusoidalSteadyState() async throws {
        // V1(SIN: 0, 1V, 100Hz) → R(1kΩ) → out → C(1µF) → GND
        // fc = 1/(2π×1k×1µ) ≈ 159.15 Hz
        // At f=100Hz: |H| = 1/√(1+(100/159.15)²) ≈ 0.847
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "vo": .real(0.0), "va": .real(1.0),
                                    "freq": .real(100.0)
                                ])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(1e-6)])

        let config = TransientConfig(
            stopTime: 50e-3, // 5 periods at 100Hz
            maxTimeStep: 200e-6,
            lteTolerance: 0.5
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)

        let waveform = result.voltageWaveform(at: out)
        #expect(waveform.count > 50)

        // Measure amplitude in the last period (steady state)
        let steadyStart = 40e-3 // last period: 40-50ms
        let steadyWaveform = waveform.filter { $0.time >= steadyStart }
        let maxV = steadyWaveform.map(\.value).max() ?? 0.0
        let minV = steadyWaveform.map(\.value).min() ?? 0.0
        let amplitude = (maxV - minV) / 2.0

        // Expected amplitude: 1/√(1+(f/fc)²)
        let fc = 1.0 / (2.0 * .pi * 1000 * 1e-6)
        let expectedAmp = 1.0 / sqrt(1.0 + pow(100.0 / fc, 2))
        #expect(abs(amplitude - expectedAmp) < 0.15,
                "Steady-state amplitude should be ~\(expectedAmp), got \(amplitude)")
    }

    // MARK: - C5: PULSE Waveform Tracking

    @Test("C5: PULSE voltage source waveform tracking")
    func pulseWaveformTracking() async throws {
        // V1(PULSE 0→5V, tr=1ms, pw=1ms, tf=1ms, per=3ms) → R(1kΩ) → GND
        // Since there's no reactive element, V(in) = V_source exactly.
        var netlist = Netlist()
        let inp = netlist.node("in")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "v1": .real(0.0), "v2": .real(5.0),
                                    "td": .real(0.0), "tr": .real(1e-3),
                                    "tf": .real(1e-3), "pw": .real(1e-3),
                                    "per": .real(3e-3)
                                ])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "0"],
                                parameters: ["r": .real(1000)])

        let config = TransientConfig(
            stopTime: 3e-3,
            maxTimeStep: 50e-6,
            lteTolerance: 0.5
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)

        // At t=0: V=0 (v1)
        let v0 = result.voltage(at: inp, timeIndex: 0)
        #expect(abs(v0) < 0.1, "At t=0, V should be ~0V, got \(v0)")

        // At t=0.5ms: rising, V ≈ 2.5V
        let idx05 = timeIndex(in: result, closest: 0.5e-3)
        let v05 = result.voltage(at: inp, timeIndex: idx05)
        #expect(abs(v05 - 2.5) < 0.5, "At t=0.5ms, V should be ~2.5V, got \(v05)")

        // At t=1.5ms: V = 5V (pulse high)
        let idx15 = timeIndex(in: result, closest: 1.5e-3)
        let v15 = result.voltage(at: inp, timeIndex: idx15)
        #expect(abs(v15 - 5.0) < 0.2, "At t=1.5ms, V should be ~5V, got \(v15)")

        // At t=2.5ms: falling, V ≈ 2.5V
        let idx25 = timeIndex(in: result, closest: 2.5e-3)
        let v25 = result.voltage(at: inp, timeIndex: idx25)
        #expect(abs(v25 - 2.5) < 0.5, "At t=2.5ms, V should be ~2.5V, got \(v25)")
    }

    // MARK: - C6: Diode Half-Wave Rectifier

    @Test("C6: Diode half-wave rectifier",
          .timeLimit(.minutes(1)))
    func diodeHalfWaveRectifier() async throws {
        // V1(SIN: 0, 5V, 1kHz) → R_in(10Ω) → anode → D1 → out → R(1kΩ) → GND
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("anode")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "vo": .real(0.0), "va": .real(5.0),
                                    "freq": .real(1000.0)
                                ])
        try netlist.addInstance(name: "R_in", typeName: "resistor", nodes: ["in", "anode"],
                                parameters: ["r": .real(10.0)])
        try netlist.addInstance(name: "D1", typeName: "diode", nodes: ["anode", "out"],
                                parameters: [:])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["out", "0"],
                                parameters: ["r": .real(1000)])

        let config = TransientConfig(
            stopTime: 2e-3,
            maxTimeStep: 1e-6,
            lteTolerance: 0.5
        )
        let convergence = ConvergenceConfig(
            reltol: 1e-3,
            vntol: 1e-4,
            maxIterations: 200,
            gmin: 1e-9
        )
        let result = try await CircuitFactory.runTransient(
            netlist, config: config, convergenceConfig: convergence
        )

        let waveform = result.voltageWaveform(at: out)
        #expect(waveform.count > 50)

        var hasPositive = false
        var negativeClamped = true
        for point in waveform {
            if point.value > 1.0 { hasPositive = true }
            if point.value < -0.5 { negativeClamped = false }
        }
        #expect(hasPositive, "Should have positive output during positive half-cycle")
        #expect(negativeClamped, "Output should be clamped near 0V during negative half-cycle")

        let maxV = waveform.map(\.value).max() ?? 0.0
        #expect(maxV > 3.0 && maxV < 5.0, "Peak output should be ~4.3V, got \(maxV)")
    }

    // MARK: - C7: Diode Rectifier with PULSE Source

    @Test("C7: Diode rectifier with PULSE source",
          .timeLimit(.minutes(1)))
    func diodeRectifierPulse() async throws {
        // PULSE source through diode to load resistor
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("mid")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "v1": .real(-5.0), "v2": .real(5.0),
                                    "td": .real(0.0), "tr": .real(100e-6),
                                    "tf": .real(100e-6), "pw": .real(400e-6),
                                    "per": .real(1e-3)
                                ])
        try netlist.addInstance(name: "R_in", typeName: "resistor", nodes: ["in", "mid"],
                                parameters: ["r": .real(10.0)])
        try netlist.addInstance(name: "D1", typeName: "diode", nodes: ["mid", "out"],
                                parameters: [:])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["out", "0"],
                                parameters: ["r": .real(1000)])

        let config = TransientConfig(
            stopTime: 2e-3,
            maxTimeStep: 5e-6,
            lteTolerance: 0.5
        )
        let convergence = ConvergenceConfig(
            reltol: 1e-3,
            vntol: 1e-4,
            maxIterations: 200,
            gmin: 1e-9
        )
        let result = try await CircuitFactory.runTransient(
            netlist, config: config, convergenceConfig: convergence
        )

        let waveform = result.voltageWaveform(at: out)
        #expect(waveform.count > 50)

        let positiveCount = waveform.filter { $0.value > 0.1 }.count
        #expect(Double(positiveCount) / Double(waveform.count) > 0.1,
                "Significant portion of output should be positive")
    }

    // MARK: - C8: BJT Switching

    @Test("C8: BJT switching transient",
          .timeLimit(.minutes(1)))
    func bjtSwitching() async throws {
        // V1(PULSE 0→5V) → Rb(10kΩ) → base, Vcc(5V) → Rc(1kΩ) → collector, emitter → GND
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("vcc")
        let col = netlist.node("col")
        let _ = netlist.node("base")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // VCC
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "v1": .real(0.0), "v2": .real(5.0),
                                    "td": .real(0.0), "tr": .real(1e-7),
                                    "tf": .real(1e-7), "pw": .real(50e-6),
                                    "per": .real(100e-6)
                                ])
        try netlist.addInstance(name: "VCC", typeName: "vsource", nodes: ["vcc", "0"],
                                parameters: ["v": .real(5.0)])
        try netlist.addInstance(name: "RB", typeName: "resistor", nodes: ["in", "base"],
                                parameters: ["r": .real(10000)])
        try netlist.addInstance(name: "RC", typeName: "resistor", nodes: ["vcc", "col"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "Q1", typeName: "npn", nodes: ["col", "base", "0"],
                                parameters: [:])

        let config = TransientConfig(
            stopTime: 100e-6,
            maxTimeStep: 1e-6,
            lteTolerance: 0.5
        )
        let result = try await CircuitFactory.runTransient(
            netlist, config: config,
            convergenceConfig: CircuitFactory.nonlinearConfig
        )

        let waveform = result.voltageWaveform(at: col)
        let maxV = waveform.map(\.value).max() ?? 0.0
        let minV = waveform.map(\.value).min() ?? 0.0
        #expect(maxV > 4.0, "OFF state Vce should be ~5V, got \(maxV)")
        #expect(minV < 1.0, "ON state Vce should be low, got \(minV)")
    }

    // MARK: - C9: MOSFET Switching

    @Test("C9: MOSFET switching transient",
          .timeLimit(.minutes(1)))
    func mosfetSwitching() async throws {
        // V1(PULSE 0→5V) → gate, Vdd(5V) → Rd(1kΩ) → drain, source → GND
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("vdd")
        let drain = netlist.node("drain")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // VDD
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "v1": .real(0.0), "v2": .real(5.0),
                                    "td": .real(0.0), "tr": .real(1e-7),
                                    "tf": .real(1e-7), "pw": .real(50e-6),
                                    "per": .real(100e-6)
                                ])
        try netlist.addInstance(name: "VDD", typeName: "vsource", nodes: ["vdd", "0"],
                                parameters: ["v": .real(5.0)])
        try netlist.addInstance(name: "RD", typeName: "resistor", nodes: ["vdd", "drain"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "M1", typeName: "nmos_l1", nodes: ["drain", "in", "0", "0"],
                                parameters: [:])

        let config = TransientConfig(
            stopTime: 100e-6,
            maxTimeStep: 1e-6,
            lteTolerance: 0.5
        )
        let result = try await CircuitFactory.runTransient(
            netlist, config: config,
            convergenceConfig: CircuitFactory.nonlinearConfig
        )

        let waveform = result.voltageWaveform(at: drain)
        let maxV = waveform.map(\.value).max() ?? 0.0
        let minV = waveform.map(\.value).min() ?? 0.0
        #expect(maxV > 4.0, "OFF state Vds should be ~5V, got \(maxV)")
        #expect(minV < 1.0, "ON state Vds should be low, got \(minV)")
    }

    // MARK: - C10: RC Charging with PULSE Source

    @Test("C10: RC charging and discharging with PULSE source")
    func rcChargingDischarging() async throws {
        // PULSE(0→2V, pw=5ms) → R(1kΩ) → out → C(1µF) → GND
        // τ = RC = 1ms
        // During pulse high: V(out) charges toward 2V
        // V(out, t) = 2(1 - e^(-t/τ))
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "v1": .real(0.0), "v2": .real(2.0),
                                    "td": .real(0.0), "tr": .real(1e-9),
                                    "tf": .real(1e-9), "pw": .real(5e-3),
                                    "per": .real(10e-3)
                                ])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(1e-6)])

        let tau = 1000.0 * 1e-6 // RC = 1ms
        let config = TransientConfig(
            stopTime: 5e-3,
            maxTimeStep: 10e-6,
            lteTolerance: 0.5
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)

        // At t=0: V(out) = 0 (DC op with v1=0)
        let v0 = result.voltage(at: out, timeIndex: 0)
        #expect(abs(v0) < 0.01, "At t=0, V(out) should be ~0V, got \(v0)")

        // At t=τ=1ms: V(out) ≈ 2(1-e^-1) ≈ 1.264V
        let tauIdx = timeIndex(in: result, closest: tau)
        let vTau = result.voltage(at: out, timeIndex: tauIdx)
        let expectedVTau = 2.0 * (1.0 - exp(-1.0))
        #expect(abs(vTau - expectedVTau) < 0.2,
                "At t=τ, V(out) should be ~\(expectedVTau)V, got \(vTau)")

        // At t=5τ=5ms: V(out) ≈ 2V (fully charged)
        let finalIdx = result.timePoints.count - 1
        let vFinal = result.voltage(at: out, timeIndex: finalIdx)
        #expect(abs(vFinal - 2.0) < 0.1,
                "At t=5τ, V(out) should be ~2V, got \(vFinal)")
    }

    // MARK: - C11: RL Current Build-up with PULSE Source

    @Test("C11: RL current build-up with PULSE source")
    func rlCurrentBuildUp() async throws {
        // PULSE(0→1V) → R(100Ω) → out → L(10mH) → GND
        // τ = L/R = 10mH/100Ω = 100µs
        // V(out) at junction: decays from V_source toward 0
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // L1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "v1": .real(0.0), "v2": .real(1.0),
                                    "td": .real(0.0), "tr": .real(1e-9),
                                    "tf": .real(1e-9), "pw": .real(1e-3),
                                    "per": .real(2e-3)
                                ])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                parameters: ["r": .real(100)])
        try netlist.addInstance(name: "L1", typeName: "inductor", nodes: ["out", "0"],
                                parameters: ["l": .real(10e-3)])

        let tau = 10e-3 / 100.0 // L/R = 100µs
        let config = TransientConfig(
            stopTime: 500e-6,
            maxTimeStep: 1e-6
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)

        // At t=0: all zero (DC op with v1=0)
        let v0 = result.voltage(at: out, timeIndex: 0)
        #expect(abs(v0) < 0.01, "At t=0, V(out) should be ~0V, got \(v0)")

        // After step: V(out) = V×e^(-t/τ) (inductor voltage decays)
        // At t=τ=100µs: V(out) ≈ 1×e^-1 ≈ 0.368V
        let tauIdx = timeIndex(in: result, closest: tau)
        let vTau = result.voltage(at: out, timeIndex: tauIdx)
        let expectedVTau = 1.0 * exp(-1.0)
        #expect(abs(vTau - expectedVTau) < 0.15,
                "At t=τ, V(out) should be ~\(expectedVTau)V, got \(vTau)")

        // At t=5τ=500µs: V(out) ≈ 0V (inductor is short, current steady)
        let finalIdx = result.timePoints.count - 1
        let vFinal = result.voltage(at: out, timeIndex: finalIdx)
        #expect(abs(vFinal) < 0.05,
                "At t=5τ, V(out) should be ~0V, got \(vFinal)")
    }

    // MARK: - C12: Long-Duration Numerical Stability

    @Test("C12: Long-duration simulation stability")
    func longDurationStability() async throws {
        // PULSE(0→1V, tr=100ns) → R(1kΩ) → C(1nF) → GND
        // τ = RC = 1µs, period = 10µs
        // Run for 10 periods
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "v1": .real(0.0), "v2": .real(1.0),
                                    "td": .real(0.0), "tr": .real(100e-9),
                                    "tf": .real(100e-9), "pw": .real(4.9e-6),
                                    "per": .real(10e-6)
                                ])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(1e-9)])

        let config = TransientConfig(
            stopTime: 100e-6,
            maxTimeStep: 100e-9,
            lteTolerance: 0.5
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)

        #expect(result.timePoints.count > 100)

        // Get voltage near t=5µs (first pulse midpoint, cap should be charged)
        let earlyIdx = timeIndex(in: result, closest: 5e-6)
        let vEarly = result.voltage(at: out, timeIndex: earlyIdx)

        // Get voltage near t=95µs (last pulse midpoint)
        let lateIdx = timeIndex(in: result, closest: 95e-6)
        let vLate = result.voltage(at: out, timeIndex: lateIdx)

        // They should be close (no drift)
        #expect(abs(vLate - vEarly) < 0.2,
                "No numerical drift: early=\(vEarly), late=\(vLate)")

        // Verify simulation completed successfully
        #expect(result.timePoints.last! >= 99e-6,
                "Simulation should reach near stop time")
    }

    // MARK: - C13: Resistive PULSE Waveform

    @Test("C13: Resistive circuit with fast PULSE waveform")
    func resistivePulse() async throws {
        // V1(PULSE 0→5V, tr=10ns, per=100ns) → R(50Ω) → GND
        // Pure resistive circuit: no reactive elements → no LTE issues
        var netlist = Netlist()
        let inp = netlist.node("in")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "v1": .real(0.0), "v2": .real(5.0),
                                    "td": .real(0.0), "tr": .real(10e-9),
                                    "tf": .real(10e-9), "pw": .real(40e-9),
                                    "per": .real(100e-9)
                                ])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "0"],
                                parameters: ["r": .real(50)])

        let config = TransientConfig(
            stopTime: 500e-9, // 5 periods
            maxTimeStep: 1e-9,
            lteTolerance: 0.5
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)

        // Verify completion
        #expect(result.timePoints.count > 10)
        #expect(result.timePoints.last! >= 400e-9)

        // Verify pulse shape: V(in) is the source voltage
        let waveform = result.voltageWaveform(at: inp)
        let maxV = waveform.map(\.value).max() ?? 0.0
        let minV = waveform.map(\.value).min() ?? 0.0
        #expect(maxV > 4.0, "Pulse should reach ~5V, got \(maxV)")
        #expect(abs(minV) < 1.0, "Pulse should return to ~0V, got \(minV)")
    }

    // MARK: - C14: RC Integrator with Sine Input

    @Test("C14: RC integrator sinusoidal response")
    func rcIntegrator() async throws {
        // V1(SIN 0, 1V, 1kHz) → R(10kΩ) → out → C(100nF) → GND
        // fc = 1/(2π×10k×100n) ≈ 159 Hz
        // f_in = 1kHz >> fc → integrator behavior
        // |H(1kHz)| = 1/√(1+(1000/159)²) ≈ 0.157
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "vo": .real(0.0), "va": .real(1.0),
                                    "freq": .real(1000.0)
                                ])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                parameters: ["r": .real(10000)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(100e-9)])

        let config = TransientConfig(
            stopTime: 5e-3, // 5 periods
            maxTimeStep: 20e-6,
            lteTolerance: 0.5
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)

        // Measure amplitude in last period (steady state)
        let waveform = result.voltageWaveform(at: out)
        let steadyWaveform = waveform.filter { $0.time >= 4e-3 }
        let maxV = steadyWaveform.map(\.value).max() ?? 0.0
        let minV = steadyWaveform.map(\.value).min() ?? 0.0
        let amplitude = (maxV - minV) / 2.0

        // Expected: |H(f)| = 1/√(1+(f/fc)²)
        let fc = 1.0 / (2.0 * .pi * 10000 * 100e-9)
        let expectedAmp = 1.0 / sqrt(1.0 + pow(1000.0 / fc, 2))
        #expect(abs(amplitude - expectedAmp) < 0.05,
                "Integrator amplitude should be ~\(expectedAmp), got \(amplitude)")
    }

    // MARK: - C15: Current Source Driven Transient

    @Test("C15: Current source pulse driving a resistor")
    func currentSourcePulse() async throws {
        // I1(PULSE 0→1mA, pw=0.49ms, per=1ms) → R(1kΩ) → GND
        // V(out) = I × R = 1mA × 1kΩ = 1V during pulse
        var netlist = Netlist()
        let out = netlist.node("out")
        try netlist.addInstance(name: "I1", typeName: "isource", nodes: ["out", "0"],
                                parameters: [
                                    "i1": .real(0.0), "i2": .real(1e-3),
                                    "td": .real(0.0), "tr": .real(10e-6),
                                    "tf": .real(10e-6), "pw": .real(0.48e-3),
                                    "per": .real(1e-3)
                                ])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["out", "0"],
                                parameters: ["r": .real(1000)])

        let config = TransientConfig(
            stopTime: 2e-3, // 2 periods
            maxTimeStep: 10e-6,
            lteTolerance: 0.5
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)

        let waveform = result.voltageWaveform(at: out)
        #expect(waveform.count > 20)

        // During pulse high (e.g., t=0.25ms): V = I × R = 1V
        let highIdx = timeIndex(in: result, closest: 0.25e-3)
        let vHigh = result.voltage(at: out, timeIndex: highIdx)
        #expect(abs(vHigh - 1.0) < 0.15,
                "During pulse, V should be ~1V (I×R), got \(vHigh)")

        // During pulse low (e.g., t=0.75ms): V = 0V
        let lowIdx = timeIndex(in: result, closest: 0.75e-3)
        let vLow = result.voltage(at: out, timeIndex: lowIdx)
        #expect(abs(vLow) < 0.15,
                "Between pulses, V should be ~0V, got \(vLow)")
    }
}

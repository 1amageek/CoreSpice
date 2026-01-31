import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

/// Transient accuracy validation tests.
///
/// These tests use tight tolerances derived from analytical solutions
/// to detect integration method accuracy degradation. Specifically,
/// they are designed to catch backward Euler (1st order) being used
/// where trapezoidal (2nd order) is expected.
@Suite("Transient Accuracy Validation Tests")
struct TransientAccuracyTests {

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

    /// Linear interpolation of a waveform at a specific time.
    private func interpolatedValue(
        in waveform: [(time: Double, value: Double)],
        at time: Double
    ) -> Double {
        guard let idx = waveform.lastIndex(where: { $0.time <= time }) else {
            return waveform.first?.value ?? 0.0
        }
        if idx == waveform.count - 1 {
            return waveform[idx].value
        }
        let t0 = waveform[idx].time
        let t1 = waveform[idx + 1].time
        let v0 = waveform[idx].value
        let v1 = waveform[idx + 1].value
        let dt = t1 - t0
        if dt < 1e-30 { return v0 }
        let frac = (time - t0) / dt
        return v0 + frac * (v1 - v0)
    }

    // MARK: - V1: RLC Overshoot Precision

    @Test("V1: RLC underdamped overshoot matches analytical solution")
    func rlcOvershootPrecision() async throws {
        // PULSE(0->1V) -> R(10) -> L(1mH) -> C(1uF) -> GND
        // zeta = R/(2*sqrt(L/C)) = 10/(2*sqrt(1e-3/1e-6)) = 0.158
        // Analytical overshoot: V_peak = 1 + exp(-pi*zeta/sqrt(1-zeta^2))
        let R = 10.0
        let L = 1e-3
        let C = 1e-6
        let zeta = R / (2.0 * sqrt(L / C))
        let omega0 = 1.0 / sqrt(L * C)
        let omegaD = omega0 * sqrt(1.0 - zeta * zeta)
        let analyticalOvershoot = 1.0 + exp(-.pi * zeta / sqrt(1.0 - zeta * zeta))

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
                                parameters: ["r": .real(R)])
        try netlist.addInstance(name: "L1", typeName: "inductor", nodes: ["n1", "out"],
                                parameters: ["l": .real(L)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(C)])

        let config = TransientConfig(
            stopTime: 2e-3,
            maxTimeStep: 1e-6
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)

        let waveform = result.voltageWaveform(at: out)
        let peaks = findPeaks(in: waveform)

        #expect(peaks.count >= 2,
                "Underdamped RLC should have >=2 peaks, got \(peaks.count)")

        // First peak should match analytical overshoot within ±0.05V
        let firstPeak = peaks[0].value
        #expect(firstPeak >= analyticalOvershoot - 0.05,
                "First peak \(firstPeak)V is below analytical \(analyticalOvershoot)V - 0.05V. Possible backward Euler numerical damping.")
        #expect(firstPeak <= analyticalOvershoot + 0.05,
                "First peak \(firstPeak)V exceeds analytical \(analyticalOvershoot)V + 0.05V")

        // Verify peak timing is approximately correct
        let expectedPeakTime = .pi / omegaD
        let peakTimeError = abs(peaks[0].time - expectedPeakTime)
        #expect(peakTimeError < expectedPeakTime * 0.1,
                "Peak timing error \(peakTimeError)s exceeds 10% of expected \(expectedPeakTime)s")

        _ = zeta  // suppress unused warning
    }

    // MARK: - V2: RC Time Constant Precision

    @Test("V2: RC charging curve matches analytical solution at multiple time constants")
    func rcTimeConstantPrecision() async throws {
        // PULSE(0->1V) -> R(1k) -> out -> C(1uF) -> GND
        // tau = RC = 1ms
        // V(t) = 1 - exp(-t/tau)
        let R = 1000.0
        let C_val = 1e-6
        let tau = R * C_val  // 1ms

        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "v1": .real(0.0), "v2": .real(1.0),
                                    "td": .real(0.0), "tr": .real(1e-9),
                                    "tf": .real(1e-9), "pw": .real(10e-3),
                                    "per": .real(20e-3)
                                ])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                parameters: ["r": .real(R)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(C_val)])

        let config = TransientConfig(
            stopTime: 4e-3,  // 4*tau
            maxTimeStep: 10e-6
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)
        let waveform = result.voltageWaveform(at: out)

        // Check at multiple time constants with tight tolerances
        let checkPoints: [(multiplier: Double, tolerance: Double)] = [
            (0.5, 0.02),
            (1.0, 0.02),
            (2.0, 0.02),
            (3.0, 0.015),
        ]

        for cp in checkPoints {
            let t = cp.multiplier * tau
            let expected = 1.0 - exp(-cp.multiplier)
            let simulated = interpolatedValue(in: waveform, at: t)
            let error = abs(simulated - expected)
            #expect(error < cp.tolerance,
                    "At t=\(cp.multiplier)tau: V=\(simulated)V, expected=\(expected)V, error=\(error)V exceeds tolerance \(cp.tolerance)V")
        }
    }

    // MARK: - V3: Convergence Order (Richardson Extrapolation)

    @Test("V3: RL integration convergence order is 2nd-order (trapezoidal)")
    func convergenceOrder() async throws {
        // Run RL circuit with step sizes h, h/2, h/4.
        // Uses inductor (not capacitor) because the inductor's trapezoidal
        // companion model uses exact solution variables (branch current,
        // node voltages) rather than finite-difference approximations.
        //
        // V(out) = V * exp(-t/tau) where tau = L/R
        // For 2nd-order method: error ratio ~ 4.0 when halving step
        // For 1st-order method: error ratio ~ 2.0
        let R = 100.0
        let L = 1e-3
        let tau = L / R  // 10us
        let tStar = tau  // measure at t=tau
        let analyticalValue = 1.0 * exp(-1.0)  // exp(-1) = 0.3679

        let h: Double = 2e-6  // base step = tau/5 (coarse enough for measurable error)

        // Helper to build and run the RL circuit with given maxTimeStep
        func runWithStep(_ maxStep: Double) async throws -> (TransientResult, Node) {
            var netlist = Netlist()
            let _ = netlist.node("in")
            let out = netlist.node("out")
            let _ = netlist.branch() // V1
            let _ = netlist.branch() // L1
            try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                    parameters: [
                                        "v1": .real(0.0), "v2": .real(1.0),
                                        "td": .real(0.0), "tr": .real(1e-9),
                                        "tf": .real(1e-9), "pw": .real(100e-6),
                                        "per": .real(200e-6)
                                    ])
            try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                    parameters: ["r": .real(R)])
            try netlist.addInstance(name: "L1", typeName: "inductor", nodes: ["out", "0"],
                                    parameters: ["l": .real(L)])

            let config = TransientConfig(
                stopTime: 15e-6,
                maxTimeStep: maxStep,
                lteTolerance: 1.0  // Keep step near maxStep
            )
            let result = try await CircuitFactory.runTransient(netlist, config: config)
            return (result, out)
        }

        let (result_h, outNode_h)   = try await runWithStep(h)
        let (result_h2, outNode_h2) = try await runWithStep(h / 2.0)
        let (result_h4, outNode_h4) = try await runWithStep(h / 4.0)

        let wf_h  = result_h.voltageWaveform(at: outNode_h)
        let wf_h2 = result_h2.voltageWaveform(at: outNode_h2)
        let wf_h4 = result_h4.voltageWaveform(at: outNode_h4)

        let v_h  = interpolatedValue(in: wf_h, at: tStar)
        let v_h2 = interpolatedValue(in: wf_h2, at: tStar)
        let v_h4 = interpolatedValue(in: wf_h4, at: tStar)

        let error_h  = abs(v_h - analyticalValue)
        let error_h2 = abs(v_h2 - analyticalValue)
        let error_h4 = abs(v_h4 - analyticalValue)

        // Convergence ratio should be ~4 for 2nd-order, ~2 for 1st-order
        // Use error_h2 > 1e-10 guard to avoid division by near-zero
        if error_h2 > 1e-10 {
            let ratio = error_h / error_h2
            #expect(ratio > 3.0,
                    "Convergence ratio error_h/error_h2 = \(ratio) (expected ~4.0 for 2nd-order, ~2.0 for 1st-order BE). errors: h=\(error_h), h/2=\(error_h2), h/4=\(error_h4)")
        }

        // Also verify h/2 -> h/4 ratio as a secondary check
        if error_h4 > 1e-10 {
            let ratio2 = error_h2 / error_h4
            #expect(ratio2 > 3.0,
                    "Secondary convergence ratio error_h2/error_h4 = \(ratio2) (expected ~4.0)")
        }
    }

    // MARK: - V4: Damping Envelope Accuracy

    @Test("V4: RLC damping envelope decay ratio matches analytical prediction")
    func dampingEnvelope() async throws {
        // Same RLC as V1
        let R = 10.0
        let L = 1e-3
        let C = 1e-6
        let zeta = R / (2.0 * sqrt(L / C))
        let omega0 = 1.0 / sqrt(L * C)
        let omegaD = omega0 * sqrt(1.0 - zeta * zeta)
        let Td = 2.0 * .pi / omegaD  // damped period

        // Theoretical decay ratio between consecutive peaks
        let theoreticalRatio = exp(-zeta * omega0 * Td)

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
                                parameters: ["r": .real(R)])
        try netlist.addInstance(name: "L1", typeName: "inductor", nodes: ["n1", "out"],
                                parameters: ["l": .real(L)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(C)])

        let config = TransientConfig(
            stopTime: 2e-3,
            maxTimeStep: 1e-6
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)

        let waveform = result.voltageWaveform(at: out)
        let peaks = findPeaks(in: waveform)

        #expect(peaks.count >= 3,
                "Need >=3 peaks for envelope analysis, got \(peaks.count)")

        // Measure decay ratio: (peak2 - Vfinal) / (peak1 - Vfinal)
        let Vfinal = 1.0
        let peak1Excess = peaks[0].value - Vfinal
        let peak2Excess = peaks[1].value - Vfinal

        #expect(peak1Excess > 0.1,
                "First peak should overshoot significantly, excess=\(peak1Excess)")

        let measuredRatio = peak2Excess / peak1Excess

        #expect(abs(measuredRatio - theoreticalRatio) < 0.06,
                "Decay ratio \(measuredRatio) differs from theoretical \(theoreticalRatio) by \(abs(measuredRatio - theoreticalRatio)). BE would give ~\(theoreticalRatio * 0.5).")

        // Also check peak3/peak2 ratio for consistency
        if peaks.count >= 3 {
            let peak3Excess = peaks[2].value - Vfinal
            if abs(peak2Excess) > 0.01 {
                let ratio23 = peak3Excess / peak2Excess
                #expect(abs(ratio23 - theoreticalRatio) < 0.08,
                        "Peak3/Peak2 ratio \(ratio23) should also match theoretical \(theoreticalRatio)")
            }
        }
    }

    // MARK: - V5: RL Current Build-up Precision

    @Test("V5: RL inductor voltage decay matches analytical solution")
    func rlPrecision() async throws {
        // PULSE(0->1V) -> R(100) -> out -> L(10mH) -> GND
        // tau = L/R = 100us
        // V(out) = V * exp(-t/tau)
        let R = 100.0
        let L = 10e-3
        let tau = L / R  // 100us

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
                                parameters: ["r": .real(R)])
        try netlist.addInstance(name: "L1", typeName: "inductor", nodes: ["out", "0"],
                                parameters: ["l": .real(L)])

        let config = TransientConfig(
            stopTime: 300e-6,
            maxTimeStep: 1e-6
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)
        let waveform = result.voltageWaveform(at: out)

        // Check at multiple time constants
        let checkPoints: [(multiplier: Double, tolerance: Double)] = [
            (0.5, 0.03),
            (1.0, 0.02),
            (2.0, 0.015),
        ]

        for cp in checkPoints {
            let t = cp.multiplier * tau
            let expected = 1.0 * exp(-cp.multiplier)
            let simulated = interpolatedValue(in: waveform, at: t)
            let error = abs(simulated - expected)
            #expect(error < cp.tolerance,
                    "At t=\(cp.multiplier)tau: V(out)=\(simulated)V, expected=\(expected)V, error=\(error)V exceeds tolerance \(cp.tolerance)V")
        }
    }

    // MARK: - V6: Sinusoidal Steady-State Amplitude Precision

    @Test("V6: RC lowpass sinusoidal amplitude matches transfer function")
    func sinusoidalAmplitudePrecision() async throws {
        // SIN(0, 1V, 1kHz) -> R(10k) -> out -> C(100nF) -> GND
        // fc = 1/(2*pi*R*C) = 159.15 Hz
        // |H(1kHz)| = 1/sqrt(1 + (f/fc)^2) = 0.157
        let R = 10000.0
        let C_val = 100e-9
        let freq = 1000.0
        let fc = 1.0 / (2.0 * .pi * R * C_val)
        let expectedAmp = 1.0 / sqrt(1.0 + pow(freq / fc, 2))

        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: [
                                    "vo": .real(0.0), "va": .real(1.0),
                                    "freq": .real(freq)
                                ])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "out"],
                                parameters: ["r": .real(R)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(C_val)])

        let config = TransientConfig(
            stopTime: 5e-3,  // 5 periods
            maxTimeStep: 20e-6
        )
        let result = try await CircuitFactory.runTransient(netlist, config: config)

        // Measure amplitude in last period (steady state)
        let waveform = result.voltageWaveform(at: out)
        let steadyWaveform = waveform.filter { $0.time >= 4e-3 }

        let maxV = steadyWaveform.map(\.value).max() ?? 0.0
        let minV = steadyWaveform.map(\.value).min() ?? 0.0
        let amplitude = (maxV - minV) / 2.0

        #expect(abs(amplitude - expectedAmp) < 0.025,
                "Steady-state amplitude \(amplitude)V, expected \(expectedAmp)V, error=\(abs(amplitude - expectedAmp))V exceeds +/-0.025V")
    }
}

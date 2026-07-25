import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("AC Integration Tests")
struct ACIntegrationTests {

    // MARK: - Helpers

    /// Find the frequency index closest to the target frequency.
    private func frequencyIndex(in result: ACResult, closest target: Double) -> Int {
        result.frequencies.enumerated().min(by: {
            abs($0.element - target) < abs($1.element - target)
        })?.offset ?? 0
    }

    // MARK: - B1: RC Lowpass Filter

    @Test("B1: RC lowpass filter frequency response")
    func rcLowpassFilter() async throws {
        let (netlist, out) = try CircuitFactory.rcLowpass(r: 1000, c: 1e-6)
        // fc = 1/(2π × 1kΩ × 1µF) ≈ 159.15 Hz
        let fc = 1.0 / (2.0 * .pi * 1000 * 1e-6)

        let sweep = FrequencySweep.decade(start: 1.0, stop: 1e6, pointsPerDecade: 20)
        let result = try await CircuitFactory.runAC(netlist, sweep: sweep)

        // f = 1 Hz: |H| ≈ 0 dB
        let lowIdx = frequencyIndex(in: result, closest: 1.0)
        let magLow = try result.magnitudeDB(at: out, frequencyIndex: lowIdx)
        #expect(abs(magLow) < 0.5, "At 1 Hz, |H| should be ~0 dB, got \(magLow)")

        // f = fc: |H| ≈ -3 dB
        let fcIdx = frequencyIndex(in: result, closest: fc)
        let magFc = try result.magnitudeDB(at: out, frequencyIndex: fcIdx)
        #expect(abs(magFc - (-3.01)) < 0.5,
                "At fc=\(fc) Hz, |H| should be ~-3 dB, got \(magFc)")

        // f = 10×fc: |H| ≈ -20 dB
        let highIdx = frequencyIndex(in: result, closest: 10 * fc)
        let magHigh = try result.magnitudeDB(at: out, frequencyIndex: highIdx)
        #expect(abs(magHigh - (-20.0)) < 1.5,
                "At 10×fc, |H| should be ~-20 dB, got \(magHigh)")

        // f = 100×fc: |H| ≈ -40 dB
        let vhighIdx = frequencyIndex(in: result, closest: 100 * fc)
        let magVHigh = try result.magnitudeDB(at: out, frequencyIndex: vhighIdx)
        #expect(abs(magVHigh - (-40.0)) < 1.5,
                "At 100×fc, |H| should be ~-40 dB, got \(magVHigh)")
    }

    // MARK: - B2: RC Highpass Filter

    @Test("B2: RC highpass filter frequency response")
    func rcHighpassFilter() async throws {
        let (netlist, out) = try CircuitFactory.rcHighpass(r: 1000, c: 1e-6)
        // fc = 1/(2π × 1kΩ × 1µF) ≈ 159.15 Hz
        let fc = 1.0 / (2.0 * .pi * 1000 * 1e-6)

        let sweep = FrequencySweep.decade(start: 1.0, stop: 1e6, pointsPerDecade: 20)
        let result = try await CircuitFactory.runAC(netlist, sweep: sweep)

        // f << fc: attenuated
        let lowIdx = frequencyIndex(in: result, closest: 1.0)
        let magLow = try result.magnitudeDB(at: out, frequencyIndex: lowIdx)
        #expect(magLow < -30.0, "At 1 Hz, highpass should be attenuated, got \(magLow)")

        // f = fc: |H| ≈ -3 dB
        let fcIdx = frequencyIndex(in: result, closest: fc)
        let magFc = try result.magnitudeDB(at: out, frequencyIndex: fcIdx)
        #expect(abs(magFc - (-3.01)) < 0.5,
                "At fc, |H| should be ~-3 dB, got \(magFc)")

        // f >> fc: |H| ≈ 0 dB
        let highIdx = frequencyIndex(in: result, closest: 100 * fc)
        let magHigh = try result.magnitudeDB(at: out, frequencyIndex: highIdx)
        #expect(abs(magHigh) < 0.5, "At 100×fc, |H| should be ~0 dB, got \(magHigh)")
    }

    // MARK: - B3: RLC Series Resonance

    @Test("B3: RLC series resonance")
    func rlcSeriesResonance() async throws {
        // R=10Ω, L=1mH, C=1µF
        // f0 = 1/(2π√(LC)) ≈ 5033 Hz, Q = (1/R)√(L/C) ≈ 3.16
        // Output = voltage across C
        let (netlist, out) = try CircuitFactory.rlcSeries(r: 10, l: 1e-3, c: 1e-6)
        let f0 = 1.0 / (2.0 * .pi * sqrt(1e-3 * 1e-6))

        let sweep = FrequencySweep.decade(start: 100, stop: 100_000, pointsPerDecade: 30)
        let result = try await CircuitFactory.runAC(netlist, sweep: sweep)

        // Find peak magnitude
        var peakMag = -Double.infinity
        var peakFreq = 0.0
        for (idx, freq) in result.frequencies.enumerated() {
            let mag = try result.magnitudeDB(at: out, frequencyIndex: idx)
            if mag > peakMag {
                peakMag = mag
                peakFreq = freq
            }
        }

        // Peak should show resonant peaking (Q > 1 → gain > 0 dB)
        #expect(peakMag > 0.0,
                "RLC series with Q>1 should show resonant peaking, peak = \(peakMag) dB at \(peakFreq) Hz")

        // Peak frequency should be near f0
        #expect(abs(peakFreq / f0 - 1.0) < 0.15,
                "Resonance peak should be near \(f0) Hz, found at \(peakFreq) Hz")

        // Verify bandpass behavior: both low and high frequency should be below peak
        let lowIdx = frequencyIndex(in: result, closest: 100.0)
        let highIdx = frequencyIndex(in: result, closest: 100_000.0)
        let magLow = try result.magnitudeDB(at: out, frequencyIndex: lowIdx)
        let magHigh = try result.magnitudeDB(at: out, frequencyIndex: highIdx)

        #expect(magLow < peakMag - 5.0,
                "Low frequency (\(magLow) dB) should be well below peak (\(peakMag) dB)")
        #expect(magHigh < peakMag - 5.0,
                "High frequency (\(magHigh) dB) should be well below peak (\(peakMag) dB)")
    }

    // MARK: - B4: RLC Parallel Resonance

    @Test("B4: RLC parallel resonance")
    func rlcParallelResonance() async throws {
        // V1(AC=1) → R_series(1Ω) → out, out → R(10kΩ)→GND, out → L(1mH)→GND, out → C(1µF)→GND
        var netlist = Netlist()
        let _ = netlist.node("in")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // L1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(0), "ac": .real(1.0)])
        try netlist.addInstance(name: "RS", typeName: "resistor", nodes: ["in", "out"],
                                parameters: ["r": .real(1.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["out", "0"],
                                parameters: ["r": .real(10_000)])
        try netlist.addInstance(name: "L1", typeName: "inductor", nodes: ["out", "0"],
                                parameters: ["l": .real(1e-3)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(1e-6)])

        let f0 = 1.0 / (2.0 * .pi * sqrt(1e-3 * 1e-6))
        let sweep = FrequencySweep.decade(start: 100, stop: 100_000, pointsPerDecade: 30)
        let result = try await CircuitFactory.runAC(netlist, sweep: sweep)

        // Find peak near f0 (parallel resonance = maximum impedance = maximum |Vout|)
        var peakMag = -Double.infinity
        var peakFreq = 0.0
        for (idx, freq) in result.frequencies.enumerated() {
            let mag = try result.magnitudeDB(at: out, frequencyIndex: idx)
            if mag > peakMag {
                peakMag = mag
                peakFreq = freq
            }
        }

        #expect(abs(peakFreq / f0 - 1.0) < 0.15,
                "Parallel resonance peak should be near \(f0) Hz, found at \(peakFreq) Hz")
    }

    // MARK: - B5: Second-Order Butterworth LPF

    @Test("B5: Second-order Butterworth lowpass filter")
    func butterworthLPF() async throws {
        // 2-stage RC approximation of Butterworth: fc = 1kHz
        // V1(AC=1) → R1 → mid → C1 → GND, mid → R2 → out → C2 → GND
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("mid")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(0), "ac": .real(1.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "mid"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["mid", "0"],
                                parameters: ["c": .real(1e-6)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["mid", "out"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "C2", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(1e-6)])

        let sweep = FrequencySweep.decade(start: 1, stop: 1e6, pointsPerDecade: 20)
        let result = try await CircuitFactory.runAC(netlist, sweep: sweep)

        // High frequency: should roll off at -40 dB/decade (2nd order)
        let highIdx = frequencyIndex(in: result, closest: 100_000)
        let magHigh = try result.magnitudeDB(at: out, frequencyIndex: highIdx)
        #expect(magHigh < -40.0,
                "At 100kHz, 2nd-order filter should be < -40 dB, got \(magHigh)")

        // Passband: should be near 0 dB at low frequency
        let lowIdx = frequencyIndex(in: result, closest: 1.0)
        let magLow = try result.magnitudeDB(at: out, frequencyIndex: lowIdx)
        #expect(abs(magLow) < 1.0,
                "Passband should be ~0 dB, got \(magLow)")
    }

    // MARK: - B6: Phase Verification

    @Test("B6: RC lowpass phase response")
    func rcLowpassPhase() async throws {
        let (netlist, out) = try CircuitFactory.rcLowpass(r: 1000, c: 1e-6)
        let fc = 1.0 / (2.0 * .pi * 1000 * 1e-6)

        let sweep = FrequencySweep.decade(start: 1.0, stop: 1e6, pointsPerDecade: 20)
        let result = try await CircuitFactory.runAC(netlist, sweep: sweep)

        // f << fc: phase ≈ 0°
        let lowIdx = frequencyIndex(in: result, closest: 1.0)
        let phaseLow = try result.phase(at: out, frequencyIndex: lowIdx)
        #expect(abs(phaseLow) < 5.0, "At 1 Hz, phase should be ~0°, got \(phaseLow)")

        // f = fc: phase ≈ -45°
        let fcIdx = frequencyIndex(in: result, closest: fc)
        let phaseFc = try result.phase(at: out, frequencyIndex: fcIdx)
        #expect(abs(phaseFc - (-45.0)) < 3.0,
                "At fc, phase should be ~-45°, got \(phaseFc)")

        // f >> fc: phase ≈ -90°
        let highIdx = frequencyIndex(in: result, closest: 100 * fc)
        let phaseHigh = try result.phase(at: out, frequencyIndex: highIdx)
        #expect(abs(phaseHigh - (-90.0)) < 5.0,
                "At 100×fc, phase should be ~-90°, got \(phaseHigh)")
    }

    // MARK: - B7: BJT Common Emitter AC Gain

    @Test("B7: BJT common emitter AC gain",
          .timeLimit(.minutes(1)))
    func bjtCommonEmitterACGain() async throws {
        // Vcc(12V) → Rc(2kΩ) → collector, Vb→Rb(100kΩ)→base, emitter→GND
        // AC input via coupling cap
        var netlist = Netlist()
        let _ = netlist.node("vcc")
        let _ = netlist.node("vbb")
        let _ = netlist.node("ac_in")
        let _ = netlist.node("base")
        let col = netlist.node("col")
        let _ = netlist.branch() // VCC
        let _ = netlist.branch() // VBB
        let _ = netlist.branch() // VAC
        try netlist.addInstance(name: "VCC", typeName: "vsource", nodes: ["vcc", "0"],
                                parameters: ["v": .real(12.0)])
        try netlist.addInstance(name: "VBB", typeName: "vsource", nodes: ["vbb", "0"],
                                parameters: ["v": .real(1.5)])
        try netlist.addInstance(name: "VAC", typeName: "vsource", nodes: ["ac_in", "0"],
                                parameters: ["v": .real(0), "ac": .real(1.0)])
        try netlist.addInstance(name: "RC", typeName: "resistor", nodes: ["vcc", "col"],
                                parameters: ["r": .real(2000)])
        try netlist.addInstance(name: "RB", typeName: "resistor", nodes: ["vbb", "base"],
                                parameters: ["r": .real(100_000)])
        try netlist.addInstance(name: "CB", typeName: "capacitor", nodes: ["ac_in", "base"],
                                parameters: ["c": .real(1e-6)])
        try netlist.addInstance(name: "Q1", typeName: "npn", nodes: ["col", "base", "0"],
                                parameters: ["is": .real(1e-16), "bf": .real(100)])

        let sweep = FrequencySweep.decade(start: 100, stop: 100_000, pointsPerDecade: 10)
        let result = try await CircuitFactory.runAC(netlist, sweep: sweep)

        // BJT CE gain: |Av| ≈ gm × Rc where gm = Ic/Vt
        let midIdx = result.frequencies.count / 2
        let mag = try result.magnitudeDB(at: col, frequencyIndex: midIdx)
        #expect(mag > 10.0, "BJT CE gain should be > 10 dB, got \(mag)")
    }

    // MARK: - B8: MOSFET Common Source AC Gain

    @Test("B8: MOSFET common source AC gain",
          .timeLimit(.minutes(1)))
    func mosfetCommonSourceACGain() async throws {
        var netlist = Netlist()
        let _ = netlist.node("vdd")
        let _ = netlist.node("vg")
        let _ = netlist.node("ac_in")
        let _ = netlist.node("gate")
        let drain = netlist.node("drain")
        let _ = netlist.branch() // VDD
        let _ = netlist.branch() // VG
        let _ = netlist.branch() // VAC
        try netlist.addInstance(name: "VDD", typeName: "vsource", nodes: ["vdd", "0"],
                                parameters: ["v": .real(5.0)])
        try netlist.addInstance(name: "VG", typeName: "vsource", nodes: ["vg", "0"],
                                parameters: ["v": .real(2.0)])
        try netlist.addInstance(name: "VAC", typeName: "vsource", nodes: ["ac_in", "0"],
                                parameters: ["v": .real(0), "ac": .real(1.0)])
        try netlist.addInstance(name: "RD", typeName: "resistor", nodes: ["vdd", "drain"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "RG", typeName: "resistor", nodes: ["vg", "gate"],
                                parameters: ["r": .real(100_000)])
        try netlist.addInstance(name: "CG", typeName: "capacitor", nodes: ["ac_in", "gate"],
                                parameters: ["c": .real(1e-6)])
        try netlist.addInstance(name: "M1", typeName: "nmos_l1", nodes: ["drain", "gate", "0", "0"],
                                parameters: ["vto": .real(0.7), "kp": .real(110e-6),
                                             "w": .real(10e-6), "l": .real(1e-6),
                                             "lambda": .real(0.04)])

        let sweep = FrequencySweep.decade(start: 100, stop: 100_000, pointsPerDecade: 10)
        let result = try await CircuitFactory.runAC(netlist, sweep: sweep)

        let midIdx = result.frequencies.count / 2
        let mag = try result.magnitudeDB(at: drain, frequencyIndex: midIdx)
        #expect(mag > 3.5, "MOSFET CS gain should be > 3.5 dB, got \(mag)")
    }

    // MARK: - B9: VCVS Feedback Amplifier

    @Test("B9: VCVS feedback amplifier closed-loop gain")
    func vcvsFeedbackAmplifier() async throws {
        // Inverting amplifier: E1(gain=1e5), Ri=1kΩ, Rf=10kΩ
        // closed-loop gain ≈ -Rf/Ri = -10 → 20 dB
        var netlist = Netlist()
        let _ = netlist.node("in")
        let inv = netlist.node("inv")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        let _ = netlist.branch() // E1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(0), "ac": .real(1.0)])
        try netlist.addInstance(name: "Ri", typeName: "resistor", nodes: ["in", "inv"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "Rf", typeName: "resistor", nodes: ["inv", "out"],
                                parameters: ["r": .real(10_000)])
        // VCVS: out = gain × (inv+ - inv-) = gain × (GND - V(inv))
        // For inverting: ctrl+ = GND, ctrl- = inv
        try netlist.addInstance(name: "E1", typeName: "vcvs", nodes: ["out", "0", "0", "inv"],
                                parameters: ["e": .real(1e5)])
        try netlist.addInstance(name: "RL", typeName: "resistor", nodes: ["out", "0"],
                                parameters: ["r": .real(100_000)])

        let sweep = FrequencySweep.single(1000.0)
        let result = try await CircuitFactory.runAC(netlist, sweep: sweep)

        let mag = try result.magnitudeDB(at: out, frequencyIndex: 0)
        // |closed-loop gain| = Rf/Ri = 10 → 20 dB
        #expect(abs(mag - 20.0) < 1.0,
                "Inverting amp closed-loop gain should be ~20 dB, got \(mag)")
    }

    // MARK: - B10: Multi-stage RC Filter

    @Test("B10: Two-stage RC filter interaction")
    func multiStageRCFilter() async throws {
        // Same as B5 — verify -40 dB/decade slope at high frequency
        var netlist = Netlist()
        let _ = netlist.node("in")
        let mid = netlist.node("mid")
        let out = netlist.node("out")
        let _ = netlist.branch()
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(0), "ac": .real(1.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "mid"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "C1", typeName: "capacitor", nodes: ["mid", "0"],
                                parameters: ["c": .real(1e-6)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["mid", "out"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "C2", typeName: "capacitor", nodes: ["out", "0"],
                                parameters: ["c": .real(1e-6)])

        let sweep = FrequencySweep.decade(start: 1, stop: 1e6, pointsPerDecade: 20)
        let result = try await CircuitFactory.runAC(netlist, sweep: sweep)

        // Measure slope between two high-frequency decades
        let f1 = 10_000.0
        let f2 = 100_000.0
        let idx1 = frequencyIndex(in: result, closest: f1)
        let idx2 = frequencyIndex(in: result, closest: f2)
        let mag1 = try result.magnitudeDB(at: out, frequencyIndex: idx1)
        let mag2 = try result.magnitudeDB(at: out, frequencyIndex: idx2)

        let slopePerDecade = mag2 - mag1
        // Two-stage RC → -40 dB/decade asymptotically
        #expect(slopePerDecade < -30.0,
                "Two-stage rolloff should approach -40 dB/dec, got \(slopePerDecade)")

        // Mid node (1st stage) should show single-stage -20 dB/dec
        let magMid1 = try result.magnitudeDB(at: mid, frequencyIndex: idx1)
        let magMid2 = try result.magnitudeDB(at: mid, frequencyIndex: idx2)
        let midSlope = magMid2 - magMid1
        #expect(midSlope > slopePerDecade,
                "First stage slope (\(midSlope)) should be less steep than output (\(slopePerDecade))")
    }

    // MARK: - B11: Decade/Linear/Single Sweep Comparison

    @Test("B11: Sweep type comparison")
    func sweepTypeComparison() async throws {
        let (netlist1, out1) = try CircuitFactory.rcLowpass(r: 1000, c: 1e-6)
        let (netlist2, out2) = try CircuitFactory.rcLowpass(r: 1000, c: 1e-6)
        let (netlist3, out3) = try CircuitFactory.rcLowpass(r: 1000, c: 1e-6)

        let fc = 1.0 / (2.0 * .pi * 1000 * 1e-6)

        // Run three different sweep types
        // Decade: wide range, logarithmic spacing
        let decadeResult = try await CircuitFactory.runAC(
            netlist1, sweep: .decade(start: 1, stop: 1e6, pointsPerDecade: 20))
        // Linear: narrow range around fc so spacing ≈ 10 Hz (adequate resolution)
        let linearResult = try await CircuitFactory.runAC(
            netlist2, sweep: .linear(start: 10, stop: 1000, points: 100))
        // Single: exact fc
        let singleResult = try await CircuitFactory.runAC(
            netlist3, sweep: .single(fc))

        // All should agree at cutoff frequency
        let decFcIdx = frequencyIndex(in: decadeResult, closest: fc)
        let linFcIdx = frequencyIndex(in: linearResult, closest: fc)
        let magDecade = try decadeResult.magnitudeDB(at: out1, frequencyIndex: decFcIdx)
        let magLinear = try linearResult.magnitudeDB(at: out2, frequencyIndex: linFcIdx)
        let magSingle = try singleResult.magnitudeDB(at: out3, frequencyIndex: 0)

        // All should be close to -3 dB
        #expect(abs(magDecade - (-3.01)) < 1.0,
                "Decade sweep at fc: \(magDecade) dB")
        #expect(abs(magSingle - (-3.01)) < 0.5,
                "Single point at fc: \(magSingle) dB")
        // Linear sweep with ~10 Hz resolution should be within 1 dB
        #expect(abs(magLinear - (-3.01)) < 1.0,
                "Linear sweep near fc: \(magLinear) dB")
    }

    // MARK: - B12: RL Highpass Filter

    @Test("B12: RL highpass filter")
    func rlHighpassFilter() async throws {
        // V1(AC=1) → L(0.1H) → out → R(1kΩ) → GND
        // fc = R/(2πL) = 1000/(2π×0.1) ≈ 1591 Hz
        let (netlist, out) = try CircuitFactory.rlHighpass(r: 1000, l: 0.1)
        let fc = 1000.0 / (2.0 * .pi * 0.1)

        let sweep = FrequencySweep.decade(start: 10, stop: 1e6, pointsPerDecade: 20)
        let result = try await CircuitFactory.runAC(netlist, sweep: sweep)

        // f << fc: attenuated
        let lowIdx = frequencyIndex(in: result, closest: 10.0)
        let magLow = try result.magnitudeDB(at: out, frequencyIndex: lowIdx)
        #expect(magLow < -30.0, "At 10 Hz, RL highpass should be attenuated, got \(magLow)")

        // f = fc: |H| ≈ -3 dB
        let fcIdx = frequencyIndex(in: result, closest: fc)
        let magFc = try result.magnitudeDB(at: out, frequencyIndex: fcIdx)
        #expect(abs(magFc - (-3.01)) < 1.0,
                "At fc=\(fc) Hz, |H| should be ~-3 dB, got \(magFc)")

        // f >> fc: |H| ≈ 0 dB
        let highIdx = frequencyIndex(in: result, closest: 100 * fc)
        let magHigh = try result.magnitudeDB(at: out, frequencyIndex: highIdx)
        #expect(abs(magHigh) < 1.0,
                "At 100×fc, |H| should be ~0 dB, got \(magHigh)")
    }

    // MARK: - B13: Octave Sweep Integration

    @Test("B13: RC lowpass filter with octave sweep")
    func rcLowpassOctaveSweep() async throws {
        // Same RC lowpass as B1 but using octave sweep
        // fc = 1/(2π × 1kΩ × 1µF) ≈ 159.15 Hz
        let (netlist, out) = try CircuitFactory.rcLowpass(r: 1000, c: 1e-6)
        let fc = 1.0 / (2.0 * .pi * 1000 * 1e-6)

        // Octave sweep: 10 Hz to 100 kHz, 10 points per octave
        // log2(100000/10) ≈ 13.3 octaves → ~133 points
        let sweep = FrequencySweep.octave(start: 10.0, stop: 100_000.0, pointsPerOctave: 10)
        let result = try await CircuitFactory.runAC(netlist, sweep: sweep)

        // Verify octave sweep generates correct frequency spacing
        let frequencies = result.frequencies
        #expect(frequencies.count > 100, "Octave sweep should generate many points")
        #expect(abs(frequencies.first! - 10.0) < 0.1, "Should start at 10 Hz")
        // Note: octave sweep may not end exactly at stop due to integer truncation of octave count
        // log2(100000/10) ≈ 13.29 octaves → 132 points → last freq ≈ 94 kHz
        #expect(frequencies.last! > 90_000.0, "Should end near 100 kHz, got \(frequencies.last!)")

        // Verify octave spacing: every 10 points should double the frequency
        if frequencies.count >= 11 {
            let ratio = frequencies[10] / frequencies[0]
            #expect(abs(ratio - 2.0) < 0.1,
                    "After 10 points (1 octave), frequency should double: got ratio \(ratio)")
        }

        // f = fc (159 Hz): |H| ≈ -3 dB
        let fcIdx = frequencyIndex(in: result, closest: fc)
        let magFc = try result.magnitudeDB(at: out, frequencyIndex: fcIdx)
        #expect(abs(magFc - (-3.01)) < 0.5,
                "At fc=\(fc) Hz, |H| should be ~-3 dB, got \(magFc)")

        // f = 8×fc (≈3 octaves above fc): |H| ≈ -18 dB
        // First-order RC: -6 dB/octave → -18 dB after 3 octaves
        let f8fc = 8.0 * fc // ≈ 1273 Hz
        let f8fcIdx = frequencyIndex(in: result, closest: f8fc)
        let mag8fc = try result.magnitudeDB(at: out, frequencyIndex: f8fcIdx)
        #expect(abs(mag8fc - (-18.0)) < 2.0,
                "At 8×fc (3 octaves), |H| should be ~-18 dB, got \(mag8fc)")

        // Verify passband: f << fc should be ~0 dB
        let lowIdx = frequencyIndex(in: result, closest: 10.0)
        let magLow = try result.magnitudeDB(at: out, frequencyIndex: lowIdx)
        #expect(abs(magLow) < 0.5, "At 10 Hz, |H| should be ~0 dB, got \(magLow)")
    }

    @Test("B14: Octave sweep matches decade sweep results")
    func octaveVsDecadeSweepConsistency() async throws {
        // Use the same circuit with both sweep types
        // Results at common frequencies should match
        let (netlist1, out1) = try CircuitFactory.rcLowpass(r: 1000, c: 1e-6)
        let (netlist2, out2) = try CircuitFactory.rcLowpass(r: 1000, c: 1e-6)

        let fc = 1.0 / (2.0 * .pi * 1000 * 1e-6)

        // Run with decade sweep
        let decadeResult = try await CircuitFactory.runAC(
            netlist1,
            sweep: .decade(start: 10.0, stop: 100_000.0, pointsPerDecade: 20)
        )

        // Run with octave sweep
        let octaveResult = try await CircuitFactory.runAC(
            netlist2,
            sweep: .octave(start: 10.0, stop: 100_000.0, pointsPerOctave: 6)
        )

        // Compare magnitudes at fc
        let decFcIdx = frequencyIndex(in: decadeResult, closest: fc)
        let octFcIdx = frequencyIndex(in: octaveResult, closest: fc)
        let magDecade = try decadeResult.magnitudeDB(at: out1, frequencyIndex: decFcIdx)
        let magOctave = try octaveResult.magnitudeDB(at: out2, frequencyIndex: octFcIdx)

        // Both should be close to -3 dB
        #expect(abs(magDecade - magOctave) < 0.5,
                "Decade (\(magDecade) dB) and octave (\(magOctave) dB) should agree at fc")

        // Compare at 1 kHz
        let decIdx1k = frequencyIndex(in: decadeResult, closest: 1000.0)
        let octIdx1k = frequencyIndex(in: octaveResult, closest: 1000.0)
        let magDec1k = try decadeResult.magnitudeDB(at: out1, frequencyIndex: decIdx1k)
        let magOct1k = try octaveResult.magnitudeDB(at: out2, frequencyIndex: octIdx1k)

        #expect(abs(magDec1k - magOct1k) < 1.0,
                "Decade (\(magDec1k) dB) and octave (\(magOct1k) dB) should agree at 1kHz")
    }
}

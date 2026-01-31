import Testing
import Foundation
@testable import CoreSpiceAnalysis
@testable import CoreSpiceCompile
@testable import CoreSpiceDevices
@testable import CoreSpiceIR
@testable import CoreSpiceEvent

@Suite("Noise Integration Tests")
struct NoiseIntegrationTests {

    /// Boltzmann constant (J/K).
    private static let kB: Double = 1.380649e-23
    /// Default temperature (300K).
    private static let temperature: Double = 300.0

    // MARK: - Helper

    private func runNoise(
        netlist: Netlist,
        outputNode: Node,
        inputSourceName: String? = nil,
        sweep: FrequencySweep
    ) async throws -> NoiseResult {
        let (plan, devices) = try CircuitFactory.compile(netlist)
        let analysis = NoiseAnalysis(
            outputNode: outputNode,
            inputSourceName: inputSourceName,
            sweep: sweep
        )
        let solver = SparseLUSolver()
        let token = CancellationToken()
        return try await analysis.run(
            plan: plan, devices: devices, solver: solver,
            observer: nil, cancellation: token
        )
    }

    // MARK: - H3: RC Filter Band-Limited Noise

    @Test("H3: RC lowpass filter band-limited noise")
    func rcFilterBandLimitedNoise() async throws {
        // V1 → R(1kΩ) → out → C(1µF) → GND
        // Integrated noise = √(kT/C) ≈ 64.2µV at 300K
        // The RC filter limits noise bandwidth: total noise = √(kT/C)
        let (netlist, out) = CircuitFactory.rcLowpass(v: 1.0, ac: 1.0, r: 1000, c: 1e-6)

        let result = try await runNoise(
            netlist: netlist,
            outputNode: out,
            sweep: FrequencySweep.decade(start: 1, stop: 1e6, pointsPerDecade: 20)
        )

        // Should have many frequency points
        #expect(result.frequencies.count > 50)

        // Low frequency PSD should match pure resistive divider: 4kTR (R only, no C at low freq)
        // At low frequency: C is open → output sees full R noise
        // PSD_low ≈ 4kT×R = 4 × 1.38e-23 × 300 × 1000 = 1.66e-17 V²/Hz
        let psdLow = result.outputNoiseDensity[0]
        let expectedPsdLow = 4.0 * Self.kB * Self.temperature * 1000.0
        let ratioLow = psdLow / expectedPsdLow
        #expect(ratioLow > 0.3 && ratioLow < 3.0,
                "Low freq PSD should be ~\(expectedPsdLow), got \(psdLow)")

        // High frequency PSD should be lower (C shorts noise)
        let psdHigh = result.outputNoiseDensity.last!
        #expect(psdHigh < psdLow,
                "High frequency noise should be attenuated by C")

        // Integrated RMS noise should be positive and reasonable
        #expect(result.integratedOutputNoise > 0)
        // Theoretical: √(kT/C) = √(1.38e-23 × 300 / 1e-6) ≈ 64.3µV
        let theoreticalRMS = sqrt(Self.kB * Self.temperature / 1e-6)
        let ratio = result.integratedOutputNoise / theoreticalRMS
        // Allow wide tolerance due to discrete frequency integration
        #expect(ratio > 0.1 && ratio < 10.0,
                "Integrated noise ~\(result.integratedOutputNoise) should be order of \(theoreticalRMS)")
    }

    // MARK: - H4: Multi-Resistor Network Noise

    @Test("H4: Three-resistor network noise contributions")
    func multiResistorNetworkNoise() async throws {
        // V1 → R1(1kΩ) → mid → R2(2kΩ) → out → R3(1kΩ) → GND
        var netlist = Netlist()
        let _ = netlist.node("in")
        let _ = netlist.node("mid")
        let out = netlist.node("out")
        let _ = netlist.branch() // V1
        try netlist.addInstance(name: "V1", typeName: "vsource", nodes: ["in", "0"],
                                parameters: ["v": .real(1.0)])
        try netlist.addInstance(name: "R1", typeName: "resistor", nodes: ["in", "mid"],
                                parameters: ["r": .real(1000)])
        try netlist.addInstance(name: "R2", typeName: "resistor", nodes: ["mid", "out"],
                                parameters: ["r": .real(2000)])
        try netlist.addInstance(name: "R3", typeName: "resistor", nodes: ["out", "0"],
                                parameters: ["r": .real(1000)])

        let result = try await runNoise(
            netlist: netlist,
            outputNode: out,
            sweep: FrequencySweep.single(1000.0)
        )

        // Should have 3 device contributions (one per resistor)
        #expect(result.deviceContributions.count == 3,
                "Should have noise from 3 resistors, got \(result.deviceContributions.count)")

        // Sum of contributions should equal total output noise
        let totalContrib = result.deviceContributions
            .map { $0.spectralDensity[0] }
            .reduce(0.0, +)
        #expect(abs(totalContrib - result.outputNoiseDensity[0]) < 1e-30,
                "Sum of contributions should equal total: \(totalContrib) vs \(result.outputNoiseDensity[0])")

        // Each contribution should be positive
        for contrib in result.deviceContributions {
            #expect(contrib.spectralDensity[0] > 0,
                    "\(contrib.noiseName) should have positive noise contribution")
        }

        // Total output noise PSD should be positive
        #expect(result.outputNoiseDensity[0] > 0)
    }

    // MARK: - H5: White Noise Frequency Independence

    @Test("H5: Resistor thermal noise is frequency-independent (white)")
    func whiteNoiseFrequencyIndependence() async throws {
        // V1 → R1(1kΩ) → out → R2(1kΩ) → GND
        // Pure resistive network → noise PSD should be constant across frequency
        let (netlist, out) = CircuitFactory.resistiveDivider(v: 1.0, r1: 1000, r2: 1000)

        let result = try await runNoise(
            netlist: netlist,
            outputNode: out,
            sweep: FrequencySweep.decade(start: 10, stop: 100_000, pointsPerDecade: 10)
        )

        #expect(result.frequencies.count > 20)
        #expect(result.outputNoiseDensity.count == result.frequencies.count)

        // All PSD values should be approximately equal (white noise)
        let psd0 = result.outputNoiseDensity[0]
        for psd in result.outputNoiseDensity {
            let ratio = psd / psd0
            #expect(ratio > 0.9 && ratio < 1.1,
                    "White noise PSD should be constant: ratio = \(ratio)")
        }

        // Verify PSD value: 4kT × R_parallel = 4kT × 500
        let expectedPSD = 4.0 * Self.kB * Self.temperature * 500.0
        let relError = abs(psd0 - expectedPSD) / expectedPSD
        #expect(relError < 0.5,
                "PSD should be ~\(expectedPSD), got \(psd0), relErr=\(relError)")
    }

    // MARK: - H6: Noise Scales with Resistance Value

    @Test("H6: Output noise increases with resistance in divider")
    func noiseScalesWithResistance() async throws {
        // Compare noise of two dividers with different resistance scales:
        // Circuit A: V1(1V) → R1(1kΩ) → out → R2(1kΩ) → GND
        // Circuit B: V1(1V) → R1(10kΩ) → out → R2(10kΩ) → GND
        // Noise PSD ∝ R_parallel, so Circuit B should have 10× more noise

        // Circuit A: R = 1kΩ
        let (netlistA, outA) = CircuitFactory.resistiveDivider(v: 1.0, r1: 1000, r2: 1000)
        let resultA = try await runNoise(
            netlist: netlistA,
            outputNode: outA,
            sweep: FrequencySweep.single(1000.0)
        )

        // Circuit B: R = 10kΩ
        let (netlistB, outB) = CircuitFactory.resistiveDivider(v: 1.0, r1: 10000, r2: 10000)
        let resultB = try await runNoise(
            netlist: netlistB,
            outputNode: outB,
            sweep: FrequencySweep.single(1000.0)
        )

        // Both should have positive noise
        #expect(resultA.outputNoiseDensity[0] > 0)
        #expect(resultB.outputNoiseDensity[0] > 0)

        // Circuit B should have higher output noise (10× R → 10× noise PSD)
        #expect(resultB.outputNoiseDensity[0] > resultA.outputNoiseDensity[0],
                "Higher R should give more noise: \(resultB.outputNoiseDensity[0]) vs \(resultA.outputNoiseDensity[0])")

        // Ratio should be ~10 (R_parallel scales by 10)
        let ratio = resultB.outputNoiseDensity[0] / resultA.outputNoiseDensity[0]
        #expect(ratio > 5 && ratio < 20,
                "Noise ratio should be ~10 (R scales by 10), got \(ratio)")
    }
}

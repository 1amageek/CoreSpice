import Testing
import Foundation
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceCompile
import CoreSpiceAnalysis
@testable import CoreSpiceOptoelectronics

@Suite("Photodiode Device Model Tests")
struct PhotodiodeTests {

    // MARK: - DC Photocurrent

    @Test("Photodiode generates correct photocurrent from optical power")
    func dcPhotocurrent() {
        // Setup: Photodiode with R=0.8 A/W, P_optical=1mW
        // Expected: I_photo = 0.8 * 1e-3 + 1e-9 (dark) ≈ 0.8 mA
        let params = PhotodiodeModelParameters(
            saturationCurrent: 1e-14,
            responsivity: 0.8,
            darkCurrent: 1e-9
        )

        let opticalInput = OpticalNode(id: 1)
        var opticalState = OpticalState(nodeCount: 2)
        // Set 1 mW optical power (sqrt(1e-3) field amplitude)
        opticalState[opticalInput] = OpticalSignal.fromPolar(
            amplitude: sqrt(1e-3), phase: 0, wavelength: 1550e-9
        )

        let power = opticalState.power(at: opticalInput)
        let expectedPhotocurrent = params.responsivity * power + params.darkCurrent

        #expect(abs(power - 1e-3) < 1e-12, "Optical power should be 1 mW")
        // I_photo = 0.8 * 1e-3 + 1e-9 = 0.800001e-3
        let expectedValue = 0.8e-3 + 1e-9
        #expect(abs(expectedPhotocurrent - expectedValue) < 1e-15, "Photocurrent should be R*P + I_dark")
    }

    @Test("Photodiode dark current flows with no optical input")
    func darkCurrent() {
        let params = PhotodiodeModelParameters(
            saturationCurrent: 1e-14,
            responsivity: 0.8,
            darkCurrent: 5e-9
        )

        let opticalInput = OpticalNode(id: 1)
        let opticalState = OpticalState(nodeCount: 2)

        let power = opticalState.power(at: opticalInput)
        let iPhoto = params.responsivity * power + params.darkCurrent

        #expect(power == 0.0, "No optical power with zero signal")
        #expect(abs(iPhoto - 5e-9) < 1e-15, "Only dark current should flow")
    }

    // MARK: - Optical Waveguide

    @Test("Waveguide attenuates signal correctly")
    func waveguideAttenuation() {
        let inputNode = OpticalNode(id: 1)
        let outputNode = OpticalNode(id: 2)

        let wg = BoundOpticalWaveguide(
            instance: Instance(name: "WG1", typeName: "waveguide", nodes: [], parameters: [:]),
            inputNode: inputNode,
            outputNode: outputNode,
            length: 0.01,       // 1 cm
            neff: 1.45,
            lossdBperCm: 0.5    // 0.5 dB/cm
        )

        // Input: 1 mW at 1550nm
        let inputSignal = OpticalSignal.fromPolar(
            amplitude: sqrt(1e-3), phase: 0, wavelength: 1550e-9
        )

        let outputs = wg.propagate(inputs: [inputNode: inputSignal])
        guard let output = outputs[outputNode] else {
            Issue.record("No output signal")
            return
        }

        // Expected: 0.5 dB loss over 1 cm
        // Power ratio = 10^(-0.5/10) ≈ 0.8913
        let expectedPowerRatio = pow(10.0, -0.5 / 10.0)
        let actualPowerRatio = output.power / inputSignal.power

        #expect(abs(actualPowerRatio - expectedPowerRatio) < 1e-6,
                "Power transfer should match 0.5 dB/cm loss")
    }

    @Test("Waveguide applies correct phase shift")
    func waveguidePhaseShift() {
        let inputNode = OpticalNode(id: 1)
        let outputNode = OpticalNode(id: 2)

        let wg = BoundOpticalWaveguide(
            instance: Instance(name: "WG1", typeName: "waveguide", nodes: [], parameters: [:]),
            inputNode: inputNode,
            outputNode: outputNode,
            length: 1550e-9,    // Exactly one wavelength
            neff: 1.0,          // neff=1 for easy calculation
            lossdBperCm: 0.0    // No loss
        )

        let inputSignal = OpticalSignal.fromPolar(
            amplitude: 1.0, phase: 0, wavelength: 1550e-9
        )

        let outputs = wg.propagate(inputs: [inputNode: inputSignal])
        guard let output = outputs[outputNode] else {
            Issue.record("No output signal")
            return
        }

        // Phase should be 2*pi*neff*L/lambda = 2*pi (one full cycle)
        // Output phase should be ~0 (modulo 2*pi)
        let phaseDiff = abs(output.phase - inputSignal.phase)
        #expect(phaseDiff < 1e-10 || abs(phaseDiff - 2 * .pi) < 1e-10,
                "Phase should be 2*pi (one full cycle)")

        // Power should be preserved (no loss)
        #expect(abs(output.power - inputSignal.power) < 1e-12,
                "Power should be preserved with no loss")
    }

    @Test("Waveguide transfer coefficient matches attenuation")
    func waveguideTransferCoefficient() {
        let inputNode = OpticalNode(id: 1)
        let outputNode = OpticalNode(id: 2)

        let wg = BoundOpticalWaveguide(
            instance: Instance(name: "WG1", typeName: "waveguide", nodes: [], parameters: [:]),
            inputNode: inputNode,
            outputNode: outputNode,
            length: 0.02,       // 2 cm
            neff: 1.45,
            lossdBperCm: 1.0    // 1 dB/cm → 2 dB total
        )

        let transfers = wg.transferCoefficients()
        #expect(transfers.count == 1)

        let expectedCoeff = pow(10.0, -2.0 / 10.0)  // 2 dB loss
        #expect(abs(transfers[0].coefficient - expectedCoeff) < 1e-10)
    }

    // MARK: - Optical Splitter

    @Test("Splitter divides power according to split ratio")
    func splitterPowerDivision() {
        let inputNode = OpticalNode(id: 1)
        let outNode1 = OpticalNode(id: 2)
        let outNode2 = OpticalNode(id: 3)

        let splitter = BoundOpticalSplitter(
            instance: Instance(name: "S1", typeName: "splitter", nodes: [], parameters: [:]),
            inputNode: inputNode,
            outputNode1: outNode1,
            outputNode2: outNode2,
            splitRatio: 0.7,
            excessLoss: 0.0
        )

        let inputSignal = OpticalSignal.fromPolar(
            amplitude: sqrt(1e-3), phase: 0, wavelength: 1550e-9
        )

        let outputs = splitter.propagate(inputs: [inputNode: inputSignal])
        let p1 = outputs[outNode1]?.power ?? 0
        let p2 = outputs[outNode2]?.power ?? 0

        #expect(abs(p1 - 0.7e-3) < 1e-9, "Output 1 should get 70% of power")
        #expect(abs(p2 - 0.3e-3) < 1e-9, "Output 2 should get 30% of power")
        #expect(abs(p1 + p2 - 1e-3) < 1e-9, "Total power should be conserved")
    }

    @Test("Splitter with excess loss reduces total output")
    func splitterExcessLoss() {
        let inputNode = OpticalNode(id: 1)
        let outNode1 = OpticalNode(id: 2)
        let outNode2 = OpticalNode(id: 3)

        let splitter = BoundOpticalSplitter(
            instance: Instance(name: "S1", typeName: "splitter", nodes: [], parameters: [:]),
            inputNode: inputNode,
            outputNode1: outNode1,
            outputNode2: outNode2,
            splitRatio: 0.5,
            excessLoss: 0.1  // 10% excess loss
        )

        let inputSignal = OpticalSignal.fromPolar(
            amplitude: sqrt(1e-3), phase: 0, wavelength: 1550e-9
        )

        let outputs = splitter.propagate(inputs: [inputNode: inputSignal])
        let p1 = outputs[outNode1]?.power ?? 0
        let p2 = outputs[outNode2]?.power ?? 0

        let totalOutput = p1 + p2
        let expectedTotal = 1e-3 * 0.9  // 90% of input

        #expect(abs(totalOutput - expectedTotal) < 1e-9,
                "Total output should be 90% of input with 10% excess loss")
        let powerDiff: Double = abs(p1 - p2)
        #expect(powerDiff < 1e-12, "50:50 split should give equal outputs")
    }

    @Test("Splitter transfer coefficients match split ratio")
    func splitterTransferCoefficients() {
        let inputNode = OpticalNode(id: 1)
        let outNode1 = OpticalNode(id: 2)
        let outNode2 = OpticalNode(id: 3)

        let splitter = BoundOpticalSplitter(
            instance: Instance(name: "S1", typeName: "splitter", nodes: [], parameters: [:]),
            inputNode: inputNode,
            outputNode1: outNode1,
            outputNode2: outNode2,
            splitRatio: 0.3,
            excessLoss: 0.05
        )

        let transfers = splitter.transferCoefficients()
        #expect(transfers.count == 2)

        let t1 = transfers.first(where: { $0.outputNode == outNode1 })?.coefficient ?? 0
        let t2 = transfers.first(where: { $0.outputNode == outNode2 })?.coefficient ?? 0

        #expect(abs(t1 - 0.3 * 0.95) < 1e-10)
        #expect(abs(t2 - 0.7 * 0.95) < 1e-10)
    }

    // MARK: - Sensitivity Propagation

    @Test("Optical sensitivity map propagates through waveguide")
    func sensitivityPropagation() {
        var sensitivity = OpticalSensitivityMap()

        // Emitter at node 1 has dP/dV_3 = 0.5 (V_3 is laser anode)
        sensitivity.set(opticalNode: 1, electricalVar: 3, value: 0.5)

        // Waveguide propagates from node 1 to node 2 with T = 0.8
        sensitivity.propagate(from: 1, to: 2, coefficient: 0.8)

        // Result: dP_2/dV_3 = 0.8 * 0.5 = 0.4
        let result = sensitivity.get(opticalNode: 2, electricalVar: 3)
        #expect(abs(result - 0.4) < 1e-15)
    }

    @Test("Sensitivity propagation through splitter creates two entries")
    func sensitivitySplitterPropagation() {
        var sensitivity = OpticalSensitivityMap()

        // Source at node 1: dP/dV_0 = 1.0
        sensitivity.set(opticalNode: 1, electricalVar: 0, value: 1.0)

        // Splitter: node 1 → node 2 (T=0.5), node 1 → node 3 (T=0.5)
        sensitivity.propagate(from: 1, to: 2, coefficient: 0.5)
        sensitivity.propagate(from: 1, to: 3, coefficient: 0.5)

        #expect(abs(sensitivity.get(opticalNode: 2, electricalVar: 0) - 0.5) < 1e-15)
        #expect(abs(sensitivity.get(opticalNode: 3, electricalVar: 0) - 0.5) < 1e-15)
    }
}

import Testing
import Foundation
import CoreSpiceIR
import CoreSpiceDevices
@testable import CoreSpiceOptoelectronics

@Suite("EO Modulator Device Model Tests")
struct EOModulatorTests {

    private func makeModulator(
        params: EOModulatorModelParameters = EOModulatorModelParameters()
    ) -> (modulator: BoundEOModulator, optIn: OpticalNode, optOut: OpticalNode) {
        let sigPos = Node(id: 1)
        let sigNeg = Node(id: 2)
        let biasPos = Node(id: 3)
        let biasNeg = Node(id: 4)
        let optIn = OpticalNode(id: 1)
        let optOut = OpticalNode(id: 2)

        let mod = BoundEOModulator(
            instance: Instance(name: "MZM1", typeName: "eomod",
                              nodes: [sigPos, sigNeg, biasPos, biasNeg], parameters: [:]),
            signalPos: sigPos,
            signalNeg: sigNeg,
            biasPos: biasPos,
            biasNeg: biasNeg,
            signalPosIdx: 0,
            signalNegIdx: 1,
            biasPosIdx: 2,
            biasNegIdx: 3,
            opticalInput: optIn,
            opticalOutput: optOut,
            parameters: params
        )

        return (mod, optIn, optOut)
    }

    private func makeState(sigP: Double, sigN: Double, biasP: Double, biasN: Double) -> SolutionState {
        let variables: [Double] = [sigP, sigN, biasP, biasN]
        let varMap: [MNAVariable: Int] = [
            .nodeVoltage(Node(id: 1)): 0,
            .nodeVoltage(Node(id: 2)): 1,
            .nodeVoltage(Node(id: 3)): 2,
            .nodeVoltage(Node(id: 4)): 3
        ]
        return SolutionState(
            variables: variables,
            previousVariables: variables,
            twoPreviousVariables: variables,
            variableMap: varMap
        )
    }

    private func opticalStateWithInput(
        power: Double, optIn: OpticalNode, nodeCount: Int = 3
    ) -> OpticalState {
        var opticalState = OpticalState(nodeCount: nodeCount)
        opticalState[optIn] = OpticalSignal.fromPolar(
            amplitude: sqrt(power), phase: 0, wavelength: 1550e-9
        )
        return opticalState
    }

    @Test("MZM at quadrature point transmits 50% of input power")
    func quadraturePoint() throws {
        let vpi = 3.5
        let params = EOModulatorModelParameters(vPi: vpi, insertionLoss: 1.0, biasPhase: 0)
        let (mod, optIn, optOut) = makeModulator(params: params)

        let state = makeState(sigP: 0, sigN: 0, biasP: vpi / 2.0, biasN: 0)
        let opticalState = opticalStateWithInput(power: 1e-3, optIn: optIn)

        let result = mod.computeOpticalOutputWithSensitivity(
            electricalState: state, opticalState: opticalState
        )

        let outputPower = try #require(result.signals[optOut]).power
        let expectedPower = 1e-3 * 0.5  // IL=1.0, cos^2(pi/4) = 0.5

        #expect(abs(outputPower - expectedPower) < 1e-9,
                "At quadrature, output should be 50% of input")
    }

    @Test("MZM at null point blocks light")
    func nullPoint() throws {
        let vpi = 3.5
        let params = EOModulatorModelParameters(vPi: vpi, insertionLoss: 0.95, biasPhase: 0)
        let (mod, optIn, optOut) = makeModulator(params: params)

        let state = makeState(sigP: 0, sigN: 0, biasP: vpi, biasN: 0)
        let opticalState = opticalStateWithInput(power: 1e-3, optIn: optIn)

        let result = mod.computeOpticalOutputWithSensitivity(
            electricalState: state, opticalState: opticalState
        )

        let outputPower = try #require(result.signals[optOut]).power
        #expect(outputPower < 1e-15, "At null point (V = Vpi), output should be ~zero")
    }

    @Test("MZM at peak point transmits maximum power")
    func peakPoint() throws {
        let params = EOModulatorModelParameters(vPi: 3.5, insertionLoss: 0.95, biasPhase: 0)
        let (mod, optIn, optOut) = makeModulator(params: params)

        let state = makeState(sigP: 0, sigN: 0, biasP: 0, biasN: 0)
        let opticalState = opticalStateWithInput(power: 1e-3, optIn: optIn)

        let result = mod.computeOpticalOutputWithSensitivity(
            electricalState: state, opticalState: opticalState
        )

        let outputPower = try #require(result.signals[optOut]).power
        let expectedPower = 1e-3 * 0.95

        #expect(abs(outputPower - expectedPower) < 1e-9,
                "At peak point, output should be IL * P_in")
    }

    @Test("MZM sensitivity is zero at peak and null points, maximum at quadrature")
    func sensitivityVsBias() {
        let vpi = 3.5
        let il = 1.0
        let params = EOModulatorModelParameters(vPi: vpi, insertionLoss: il, biasPhase: 0)
        let (mod, optIn, _) = makeModulator(params: params)
        let opticalState = opticalStateWithInput(power: 1e-3, optIn: optIn)

        // At peak (V=0): dT/dV = -IL * sin(0) * pi/(2*Vpi) = 0
        let peakState = makeState(sigP: 0, sigN: 0, biasP: 0, biasN: 0)
        let peakResult = mod.computeOpticalOutputWithSensitivity(
            electricalState: peakState, opticalState: opticalState
        )
        let peakLocalSens = peakResult.sensitivities.filter { $0.electricalVarIndex == 2 }
        let peakSensValue = peakLocalSens.first?.dPdV ?? 0
        #expect(abs(peakSensValue) < 1e-15, "Sensitivity at peak should be zero")

        // At null (V=Vpi): dT/dV = -IL * sin(pi) * pi/(2*Vpi) ~ 0
        let nullState = makeState(sigP: 0, sigN: 0, biasP: vpi, biasN: 0)
        let nullResult = mod.computeOpticalOutputWithSensitivity(
            electricalState: nullState, opticalState: opticalState
        )
        let nullLocalSens = nullResult.sensitivities.filter { $0.electricalVarIndex == 2 }
        let nullSensValue = nullLocalSens.first?.dPdV ?? 0
        #expect(abs(nullSensValue) < 1e-12, "Sensitivity at null point should be ~zero")

        // At quadrature (V=Vpi/2): maximum magnitude sensitivity
        // arg = pi * Vpi/2 / (2*Vpi) = pi/4
        // dT/dV = -IL * sin(2*pi/4) * pi/(2*Vpi) = -sin(pi/2) * pi/(2*Vpi) = -pi/(2*Vpi)
        // dP_out/dV = P_in * dT/dV = -1e-3 * pi/(2*3.5)
        let quadState = makeState(sigP: 0, sigN: 0, biasP: vpi / 2.0, biasN: 0)
        let quadResult = mod.computeOpticalOutputWithSensitivity(
            electricalState: quadState, opticalState: opticalState
        )
        let quadLocalSens = quadResult.sensitivities.filter { $0.electricalVarIndex == 2 }
        let quadSensValue = quadLocalSens.first?.dPdV ?? 0
        let expectedQuadSens = -1e-3 * il * 1.0 * .pi / (2.0 * vpi)
        #expect(abs(quadSensValue - expectedQuadSens) < 1e-9,
                "Sensitivity at quadrature should match analytical value")
        #expect(quadSensValue < 0, "Sensitivity should be negative at quadrature")
    }

    @Test("MZM propagates upstream sensitivities through modulator")
    func upstreamSensitivityPropagation() throws {
        let params = EOModulatorModelParameters(vPi: 3.5, insertionLoss: 0.95, biasPhase: 0)
        let (mod, optIn, _) = makeModulator(params: params)

        var opticalState = opticalStateWithInput(power: 1e-3, optIn: optIn)
        // Upstream sensitivity: dP_in/dV_laser_anode = 0.5
        // Using electricalVar=10 as a hypothetical upstream laser anode index
        opticalState.sensitivities[opticalNode: 1, electricalVariable: 10] = 0.5

        // At peak point (V=0): T_power = IL = 0.95
        let state = makeState(sigP: 0, sigN: 0, biasP: 0, biasN: 0)
        let result = mod.computeOpticalOutputWithSensitivity(
            electricalState: state, opticalState: opticalState
        )

        // Upstream propagation: dP_out/dV_10 = T_power * dP_in/dV_10 = 0.95 * 0.5 = 0.475
        let upstreamSens = try #require(
            result.sensitivities.first(where: { $0.electricalVarIndex == 10 }),
            "Should propagate upstream sensitivity"
        )
        #expect(abs(upstreamSens.dPdV - 0.475) < 1e-9,
                "Propagated sensitivity should be T * dP_in/dV")
    }

    @Test("MZM signal port has correct polarity")
    func signalPortPolarity() throws {
        let vpi = 3.5
        let params = EOModulatorModelParameters(vPi: vpi, insertionLoss: 1.0, biasPhase: 0)
        let (mod, optIn, _) = makeModulator(params: params)
        let opticalState = opticalStateWithInput(power: 1e-3, optIn: optIn)

        // At quadrature via signal port
        let state = makeState(sigP: vpi / 2.0, sigN: 0, biasP: 0, biasN: 0)
        let result = mod.computeOpticalOutputWithSensitivity(
            electricalState: state, opticalState: opticalState
        )

        let sigPosSens = try #require(
            result.sensitivities.first(where: { $0.electricalVarIndex == 0 })
        )
        let sigNegSens = try #require(
            result.sensitivities.first(where: { $0.electricalVarIndex == 1 })
        )

        // Opposite polarity
        #expect(abs(sigPosSens.dPdV + sigNegSens.dPdV) < 1e-15,
                "Signal port sensitivities should have opposite signs")
    }

    @Test("MZM electrode thermal noise")
    func electrodeThermalNoise() {
        let rElec = 50.0
        let params = EOModulatorModelParameters(electrodeResistance: rElec)
        let (mod, _, _) = makeModulator(params: params)

        let state = makeState(sigP: 0, sigN: 0, biasP: 0, biasN: 0)
        let noise = mod.noiseContributions(
            state: state, opticalState: OpticalState(nodeCount: 3), frequency: 1e9
        )

        #expect(noise.count == 1)
        let k = 1.380649e-23
        let t = 300.15
        let expectedNoise = 4.0 * k * t / rElec
        #expect(abs(noise[0].currentSpectralDensity - expectedNoise) < 1e-30)
    }

    @Test("MZM with no optical input produces no output")
    func noOpticalInput() throws {
        let params = EOModulatorModelParameters()
        let (mod, _, optOut) = makeModulator(params: params)

        let state = makeState(sigP: 0, sigN: 0, biasP: 1.75, biasN: 0)
        let opticalState = OpticalState(nodeCount: 3)
        let result = mod.computeOpticalOutputWithSensitivity(
            electricalState: state, opticalState: opticalState
        )

        let outputPower = try #require(result.signals[optOut]).power
        #expect(outputPower == 0, "No input light should produce no output")
    }

    @Test("MZM bias phase offset shifts transfer function")
    func biasPhaseOffset() throws {
        let vpi = 3.5
        // With bias phase = pi/2, the peak shifts to V = -Vpi/2
        let params = EOModulatorModelParameters(
            vPi: vpi, insertionLoss: 1.0, biasPhase: .pi / 2.0
        )
        let (mod, optIn, optOut) = makeModulator(params: params)
        let opticalState = opticalStateWithInput(power: 1e-3, optIn: optIn)

        // At V=0 with phi_0 = pi/2: arg = pi*0/(2*Vpi) + pi/2 = pi/2
        // T = cos^2(pi/2) = 0
        let state = makeState(sigP: 0, sigN: 0, biasP: 0, biasN: 0)
        let result = mod.computeOpticalOutputWithSensitivity(
            electricalState: state, opticalState: opticalState
        )

        let outputPower = try #require(result.signals[optOut]).power
        #expect(outputPower < 1e-15, "With phi_0=pi/2, V=0 should be at null point")
    }
}

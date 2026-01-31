import Testing
import Foundation
import CoreSpiceIR
import CoreSpiceDevices
@testable import CoreSpiceOptoelectronics

@Suite("LED Device Model Tests")
struct LEDTests {

    @Test("LED emits optical power proportional to forward current")
    func dcOpticalPower() {
        let params = LEDModelParameters(
            saturationCurrent: 1e-14,
            emissionCoefficient: 2.0,
            externalQuantumEfficiency: 0.1,
            peakWavelength: 850e-9
        )

        // Power per current: eta_ext * h*nu / q
        let h = 6.62607015e-34
        let c = 299792458.0
        let q = 1.602176634e-19
        let photonEnergy = h * c / 850e-9
        let expectedFactor = 0.1 * photonEnergy / q

        #expect(abs(params.powerPerCurrent - expectedFactor) < 1e-10)

        // At 20 mA forward current: P = factor * I
        let current = 20e-3
        let expectedPower = expectedFactor * current

        #expect(expectedPower > 0)
        #expect(abs(expectedPower - params.powerPerCurrent * current) < 1e-15)
    }

    @Test("LED provides correct sensitivities for forward-mode propagation")
    func sensitivityPropagation() {
        let params = LEDModelParameters(
            saturationCurrent: 1e-14,
            emissionCoefficient: 2.0,
            externalQuantumEfficiency: 0.1,
            peakWavelength: 850e-9
        )

        let anodeNode = Node(id: 1)
        let cathodeNode = Node(id: 2)
        let optOut = OpticalNode(id: 1)

        let led = BoundLED(
            instance: Instance(name: "LED1", typeName: "led", nodes: [anodeNode, cathodeNode], parameters: [:]),
            anode: anodeNode,
            cathode: cathodeNode,
            anodeIdx: 0,
            cathodeIdx: 1,
            opticalOutput: optOut,
            parameters: params
        )

        // Forward bias: anode at 1.5 V, cathode at 0 V
        let variables: [Double] = [1.5, 0.0]
        let varMap: [MNAVariable: Int] = [
            .nodeVoltage(anodeNode): 0,
            .nodeVoltage(cathodeNode): 1
        ]
        let state = SolutionState(
            variables: variables,
            previousVariables: variables,
            twoPreviousVariables: variables,
            variableMap: varMap
        )

        let opticalState = OpticalState(nodeCount: 2)
        let result = led.computeOpticalOutputWithSensitivity(
            electricalState: state,
            opticalState: opticalState
        )

        // Should have output signal at the optical output node
        #expect(result.signals[optOut] != nil)
        let signal = result.signals[optOut]!
        #expect(signal.power > 0, "LED should emit light in forward bias")

        // Should have sensitivities for both anode and cathode
        #expect(result.sensitivities.count == 2, "Should have dP/dV for anode and cathode")

        let anodeSens = result.sensitivities.first(where: { $0.electricalVarIndex == 0 })
        let cathodeSens = result.sensitivities.first(where: { $0.electricalVarIndex == 1 })

        #expect(anodeSens != nil, "Should have anode sensitivity")
        #expect(cathodeSens != nil, "Should have cathode sensitivity")

        // dP/dV_anode should be positive (more voltage -> more current -> more light)
        #expect(anodeSens!.dPdV > 0)
        // dP/dV_cathode should be negative (opposite sign)
        #expect(cathodeSens!.dPdV < 0)
        // Magnitudes should be equal
        #expect(abs(anodeSens!.dPdV + cathodeSens!.dPdV) < 1e-15)
    }

    @Test("LED does not emit light in reverse bias")
    func reversebiasNoEmission() {
        let params = LEDModelParameters()

        let anodeNode = Node(id: 1)
        let cathodeNode = Node(id: 2)
        let optOut = OpticalNode(id: 1)

        let led = BoundLED(
            instance: Instance(name: "LED1", typeName: "led", nodes: [anodeNode, cathodeNode], parameters: [:]),
            anode: anodeNode,
            cathode: cathodeNode,
            anodeIdx: 0,
            cathodeIdx: 1,
            opticalOutput: optOut,
            parameters: params
        )

        // Reverse bias: anode at 0 V, cathode at 2 V
        let variables: [Double] = [0.0, 2.0]
        let varMap: [MNAVariable: Int] = [
            .nodeVoltage(anodeNode): 0,
            .nodeVoltage(cathodeNode): 1
        ]
        let state = SolutionState(
            variables: variables,
            previousVariables: variables,
            twoPreviousVariables: variables,
            variableMap: varMap
        )

        let opticalState = OpticalState(nodeCount: 2)
        let result = led.computeOpticalOutputWithSensitivity(
            electricalState: state,
            opticalState: opticalState
        )

        let signal = result.signals[optOut]!
        // In deep reverse, current is negative -> max(id, 0) = 0 -> no light
        #expect(signal.power < 1e-20, "LED should not emit in reverse bias")
        #expect(result.sensitivities.isEmpty, "No sensitivities in reverse bias")
    }
}

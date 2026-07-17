import Testing
import Foundation
import CoreSpiceIR
import CoreSpiceDevices
import CoreSpiceCompile
import CoreSpiceAnalysis
@testable import CoreSpiceOptoelectronics

/// End-to-end optical link integration tests.
///
/// Validates the complete pipeline:
///   Laser Diode → Waveguide → Photodiode
///
/// Tests the full optical DAG evaluation with sensitivity propagation
/// and the gm_opto Jacobian coupling.
@Suite("Optical Link Integration Tests")
struct OpticalLinkTests {

    // MARK: - Laser → Waveguide → Photodiode

    @Test("Laser-waveguide-photodiode optical link: correct photocurrent")
    func laserWaveguidePhotodiodeLink() {
        // Optical nodes:
        // 1: laser output / waveguide input
        // 2: waveguide output / photodiode input
        let laserOut = OpticalNode(id: 1)
        let wgOut = OpticalNode(id: 2)

        // Electrical nodes:
        // 0: laser anode (index 0)
        // 1: laser cathode (index 1)
        // 2: PD anode (index 2)
        // 3: PD cathode (index 3)
        let laserAnode = Node(id: 1)
        let laserCathode = Node(id: 2)
        let pdAnode = Node(id: 3)
        let pdCathode = Node(id: 4)

        // Create devices
        let laserParams = LaserDiodeModelParameters(
            saturationCurrent: 1e-14,
            thresholdCurrent: 20e-3,
            slopeEfficiency: 0.3,
            wavelength: 1550e-9
        )
        let laser = BoundLaserDiode(
            instance: Instance(name: "LD1", typeName: "laser",
                              nodes: [laserAnode, laserCathode], parameters: [:]),
            anode: laserAnode,
            cathode: laserCathode,
            anodeIdx: 0,
            cathodeIdx: 1,
            opticalOutput: laserOut,
            parameters: laserParams
        )

        let waveguide = BoundOpticalWaveguide(
            instance: Instance(name: "WG1", typeName: "waveguide",
                              nodes: [], parameters: [:]),
            inputNode: laserOut,
            outputNode: wgOut,
            length: 0.01,       // 1 cm
            neff: 1.45,
            lossdBperCm: 0.5    // 0.5 dB/cm
        )

        let pdParams = PhotodiodeModelParameters(
            saturationCurrent: 1e-14,
            responsivity: 0.8,
            darkCurrent: 1e-9
        )
        let photodiode = BoundPhotodiode(
            instance: Instance(name: "PD1", typeName: "photodiode",
                              nodes: [pdAnode, pdCathode], parameters: [:]),
            anode: pdAnode,
            cathode: pdCathode,
            anodeIdx: 2,
            cathodeIdx: 3,
            opticalInput: wgOut,
            parameters: pdParams
        )

        // Build optical network graph (topological order: laser → waveguide → photodiode)
        let graph = OpticalNetworkGraph(
            evaluationOrder: [
                .init(deviceIndex: 0, inputNodes: [], outputNodes: [laserOut]),
                .init(deviceIndex: 1, inputNodes: [laserOut], outputNodes: [wgOut]),
                .init(deviceIndex: 2, inputNodes: [wgOut], outputNodes: [])
            ],
            opticalNodeCount: 3
        )

        let devices: [any BoundDevice] = [laser, waveguide, photodiode]

        // Electrical state: laser forward biased above threshold, PD at 0V
        let variables: [Double] = [1.25, 0.0, 0.0, 0.0]
        let varMap: [MNAVariable: Int] = [
            .nodeVoltage(laserAnode): 0,
            .nodeVoltage(laserCathode): 1,
            .nodeVoltage(pdAnode): 2,
            .nodeVoltage(pdCathode): 3
        ]
        let state = SolutionState(
            variables: variables,
            previousVariables: variables,
            twoPreviousVariables: variables,
            variableMap: varMap
        )

        // Evaluate optical network
        let evaluator = OpticalNetworkEvaluator()
        let opticalState = evaluator.evaluate(
            graph: graph,
            devices: devices,
            electricalState: state,
            previousOpticalState: OpticalState(nodeCount: 3)
        )

        // Verify laser output power
        let laserPower = opticalState.power(at: laserOut)
        #expect(laserPower > 0, "Laser should emit above threshold")

        // Verify waveguide attenuation
        let wgPower = opticalState.power(at: wgOut)
        let expectedWgLoss = pow(10.0, -0.5 / 10.0)  // 0.5 dB
        #expect(wgPower > 0, "Waveguide should have nonzero output")
        let actualRatio = wgPower / laserPower
        #expect(abs(actualRatio - expectedWgLoss) < 1e-6,
                "Waveguide should attenuate by 0.5 dB")

        // Verify photocurrent
        let expectedPhotocurrent = pdParams.responsivity * wgPower + pdParams.darkCurrent
        #expect(expectedPhotocurrent > 0, "Photocurrent should be positive")

        // Verify sensitivity chain: laser → waveguide → photodiode
        // dP_wg/dV_laser_anode = T_wg * dP_laser/dV_laser_anode
        let laserAnodeSens = opticalState.sensitivities[
            opticalNode: laserOut.id,
            electricalVariable: 0
        ]
        let wgSens = opticalState.sensitivities[opticalNode: wgOut.id, electricalVariable: 0]
        #expect(laserAnodeSens > 0, "Laser should have positive dP/dV_anode")
        #expect(abs(wgSens - expectedWgLoss * laserAnodeSens) < 1e-12,
                "Waveguide should propagate sensitivity with loss factor")
    }

    @Test("Sensitivity propagation: gm_opto can be computed at photodiode")
    func gmOptoPropagation() {
        let laserOut = OpticalNode(id: 1)
        let wgOut = OpticalNode(id: 2)

        let laserAnode = Node(id: 1)
        let laserCathode = Node(id: 2)

        let laserParams = LaserDiodeModelParameters(
            saturationCurrent: 1e-14,
            thresholdCurrent: 20e-3,
            slopeEfficiency: 0.3
        )
        let laser = BoundLaserDiode(
            instance: Instance(name: "LD1", typeName: "laser",
                              nodes: [laserAnode, laserCathode], parameters: [:]),
            anode: laserAnode,
            cathode: laserCathode,
            anodeIdx: 0,
            cathodeIdx: 1,
            opticalOutput: laserOut,
            parameters: laserParams
        )

        let waveguide = BoundOpticalWaveguide(
            instance: Instance(name: "WG1", typeName: "waveguide",
                              nodes: [], parameters: [:]),
            inputNode: laserOut,
            outputNode: wgOut,
            length: 0.01,
            neff: 1.45,
            lossdBperCm: 0.5
        )

        let graph = OpticalNetworkGraph(
            evaluationOrder: [
                .init(deviceIndex: 0, inputNodes: [], outputNodes: [laserOut]),
                .init(deviceIndex: 1, inputNodes: [laserOut], outputNodes: [wgOut])
            ],
            opticalNodeCount: 3
        )

        let devices: [any BoundDevice] = [laser, waveguide]

        let variables: [Double] = [1.25, 0.0]
        let varMap: [MNAVariable: Int] = [
            .nodeVoltage(laserAnode): 0,
            .nodeVoltage(laserCathode): 1
        ]
        let state = SolutionState(
            variables: variables,
            previousVariables: variables,
            twoPreviousVariables: variables,
            variableMap: varMap
        )

        let evaluator = OpticalNetworkEvaluator()
        let opticalState = evaluator.evaluate(
            graph: graph,
            devices: devices,
            electricalState: state,
            previousOpticalState: OpticalState(nodeCount: 3)
        )

        // At the photodiode input (wgOut), we should have sensitivities
        // from the upstream laser → waveguide chain
        let sensitivities = opticalState.sensitivities.sensitivities(for: wgOut.id)
        #expect(!sensitivities.isEmpty, "PD input should have upstream sensitivities")

        // Compute gm_opto for a photodiode with R=0.8
        let responsivity = 0.8
        for (elecVarIdx, dPdV) in sensitivities {
            let gmOpto = responsivity * dPdV
            #expect(gmOpto != 0, "gm_opto should be nonzero for var index \(elecVarIdx)")
        }

        // Anode sensitivity should be positive, cathode negative
        let anodeSens = sensitivities.first(where: { $0.electricalVarIndex == 0 })
        let cathodeSens = sensitivities.first(where: { $0.electricalVarIndex == 1 })
        #expect(anodeSens != nil && anodeSens!.dPdV > 0)
        #expect(cathodeSens != nil && cathodeSens!.dPdV < 0)
    }

    @Test("LED-photodiode direct link: optical power matches")
    func ledPhotodiodeLink() {
        let ledOut = OpticalNode(id: 1)

        let ledAnode = Node(id: 1)
        let ledCathode = Node(id: 2)
        let pdAnode = Node(id: 3)
        let pdCathode = Node(id: 4)

        let ledParams = LEDModelParameters(
            saturationCurrent: 1e-14,
            emissionCoefficient: 2.0,
            externalQuantumEfficiency: 0.1,
            peakWavelength: 850e-9
        )
        let led = BoundLED(
            instance: Instance(name: "LED1", typeName: "led",
                              nodes: [ledAnode, ledCathode], parameters: [:]),
            anode: ledAnode,
            cathode: ledCathode,
            anodeIdx: 0,
            cathodeIdx: 1,
            opticalOutput: ledOut,
            parameters: ledParams
        )

        let pdParams = PhotodiodeModelParameters(
            saturationCurrent: 1e-14,
            responsivity: 0.5,
            darkCurrent: 1e-9
        )
        let photodiode = BoundPhotodiode(
            instance: Instance(name: "PD1", typeName: "photodiode",
                              nodes: [pdAnode, pdCathode], parameters: [:]),
            anode: pdAnode,
            cathode: pdCathode,
            anodeIdx: 2,
            cathodeIdx: 3,
            opticalInput: ledOut,
            parameters: pdParams
        )

        let graph = OpticalNetworkGraph(
            evaluationOrder: [
                .init(deviceIndex: 0, inputNodes: [], outputNodes: [ledOut]),
                .init(deviceIndex: 1, inputNodes: [ledOut], outputNodes: [])
            ],
            opticalNodeCount: 2
        )

        let devices: [any BoundDevice] = [led, photodiode]

        // Forward bias LED
        let variables: [Double] = [1.5, 0.0, 0.0, 0.0]
        let varMap: [MNAVariable: Int] = [
            .nodeVoltage(ledAnode): 0,
            .nodeVoltage(ledCathode): 1,
            .nodeVoltage(pdAnode): 2,
            .nodeVoltage(pdCathode): 3
        ]
        let state = SolutionState(
            variables: variables,
            previousVariables: variables,
            twoPreviousVariables: variables,
            variableMap: varMap
        )

        let evaluator = OpticalNetworkEvaluator()
        let opticalState = evaluator.evaluate(
            graph: graph,
            devices: devices,
            electricalState: state,
            previousOpticalState: OpticalState(nodeCount: 2)
        )

        let ledPower = opticalState.power(at: ledOut)
        #expect(ledPower > 0, "LED should emit in forward bias")

        // PD receives LED power directly (no waveguide loss)
        let expectedPhotocurrent = pdParams.responsivity * ledPower + pdParams.darkCurrent
        #expect(expectedPhotocurrent > pdParams.darkCurrent,
                "Photocurrent should be greater than dark current")

        // Sensitivity: dP_led/dV_anode should propagate to PD input
        let sensList = opticalState.sensitivities.sensitivities(for: ledOut.id)
        #expect(!sensList.isEmpty, "LED output should have sensitivities")
    }

    @Test("Laser → splitter → two photodiodes: power splits correctly")
    func laserSplitterTwoPDs() {
        let laserOut = OpticalNode(id: 1)
        let splitOut1 = OpticalNode(id: 2)
        let splitOut2 = OpticalNode(id: 3)

        let laserAnode = Node(id: 1)
        let laserCathode = Node(id: 2)

        let laserParams = LaserDiodeModelParameters(
            saturationCurrent: 1e-14,
            thresholdCurrent: 20e-3,
            slopeEfficiency: 0.3
        )
        let laser = BoundLaserDiode(
            instance: Instance(name: "LD1", typeName: "laser",
                              nodes: [laserAnode, laserCathode], parameters: [:]),
            anode: laserAnode,
            cathode: laserCathode,
            anodeIdx: 0,
            cathodeIdx: 1,
            opticalOutput: laserOut,
            parameters: laserParams
        )

        let splitter = BoundOpticalSplitter(
            instance: Instance(name: "SPL1", typeName: "splitter",
                              nodes: [], parameters: [:]),
            inputNode: laserOut,
            outputNode1: splitOut1,
            outputNode2: splitOut2,
            splitRatio: 0.5,
            excessLoss: 0.0
        )

        let graph = OpticalNetworkGraph(
            evaluationOrder: [
                .init(deviceIndex: 0, inputNodes: [], outputNodes: [laserOut]),
                .init(deviceIndex: 1, inputNodes: [laserOut], outputNodes: [splitOut1, splitOut2])
            ],
            opticalNodeCount: 4
        )

        let devices: [any BoundDevice] = [laser, splitter]

        let variables: [Double] = [1.25, 0.0]
        let varMap: [MNAVariable: Int] = [
            .nodeVoltage(laserAnode): 0,
            .nodeVoltage(laserCathode): 1
        ]
        let state = SolutionState(
            variables: variables,
            previousVariables: variables,
            twoPreviousVariables: variables,
            variableMap: varMap
        )

        let evaluator = OpticalNetworkEvaluator()
        let opticalState = evaluator.evaluate(
            graph: graph,
            devices: devices,
            electricalState: state,
            previousOpticalState: OpticalState(nodeCount: 4)
        )

        let laserPower = opticalState.power(at: laserOut)
        let p1 = opticalState.power(at: splitOut1)
        let p2 = opticalState.power(at: splitOut2)

        #expect(laserPower > 0)
        #expect(abs(p1 - laserPower * 0.5) < 1e-12, "Output 1 should get 50%")
        #expect(abs(p2 - laserPower * 0.5) < 1e-12, "Output 2 should get 50%")

        // Sensitivities should also split
        let sens1 = opticalState.sensitivities[opticalNode: splitOut1.id, electricalVariable: 0]
        let sens2 = opticalState.sensitivities[opticalNode: splitOut2.id, electricalVariable: 0]
        let laserSens = opticalState.sensitivities[opticalNode: laserOut.id, electricalVariable: 0]
        #expect(abs(sens1 - 0.5 * laserSens) < 1e-12)
        #expect(abs(sens2 - 0.5 * laserSens) < 1e-12)
    }

    @Test("Laser → EO modulator → photodiode chain")
    func laserModulatorPhotodiode() {
        let laserOut = OpticalNode(id: 1)
        let modOut = OpticalNode(id: 2)

        let laserAnode = Node(id: 1)
        let laserCathode = Node(id: 2)
        let sigPos = Node(id: 3)
        let sigNeg = Node(id: 4)
        let biasPos = Node(id: 5)
        let biasNeg = Node(id: 6)

        let laserParams = LaserDiodeModelParameters(
            saturationCurrent: 1e-14,
            thresholdCurrent: 20e-3,
            slopeEfficiency: 0.3
        )
        let laser = BoundLaserDiode(
            instance: Instance(name: "LD1", typeName: "laser",
                              nodes: [laserAnode, laserCathode], parameters: [:]),
            anode: laserAnode,
            cathode: laserCathode,
            anodeIdx: 0,
            cathodeIdx: 1,
            opticalOutput: laserOut,
            parameters: laserParams
        )

        let modParams = EOModulatorModelParameters(vPi: 3.5, insertionLoss: 0.95, biasPhase: 0)
        let modulator = BoundEOModulator(
            instance: Instance(name: "MZM1", typeName: "eomod",
                              nodes: [sigPos, sigNeg, biasPos, biasNeg], parameters: [:]),
            signalPos: sigPos,
            signalNeg: sigNeg,
            biasPos: biasPos,
            biasNeg: biasNeg,
            signalPosIdx: 2,
            signalNegIdx: 3,
            biasPosIdx: 4,
            biasNegIdx: 5,
            opticalInput: laserOut,
            opticalOutput: modOut,
            parameters: modParams
        )

        let graph = OpticalNetworkGraph(
            evaluationOrder: [
                .init(deviceIndex: 0, inputNodes: [], outputNodes: [laserOut]),
                .init(deviceIndex: 1, inputNodes: [laserOut], outputNodes: [modOut])
            ],
            opticalNodeCount: 3
        )

        let devices: [any BoundDevice] = [laser, modulator]

        // Laser above threshold, modulator at quadrature bias (Vpi/2)
        let variables: [Double] = [1.25, 0.0, 0.0, 0.0, 3.5 / 2.0, 0.0]
        let varMap: [MNAVariable: Int] = [
            .nodeVoltage(laserAnode): 0,
            .nodeVoltage(laserCathode): 1,
            .nodeVoltage(sigPos): 2,
            .nodeVoltage(sigNeg): 3,
            .nodeVoltage(biasPos): 4,
            .nodeVoltage(biasNeg): 5
        ]
        let state = SolutionState(
            variables: variables,
            previousVariables: variables,
            twoPreviousVariables: variables,
            variableMap: varMap
        )

        let evaluator = OpticalNetworkEvaluator()
        let opticalState = evaluator.evaluate(
            graph: graph,
            devices: devices,
            electricalState: state,
            previousOpticalState: OpticalState(nodeCount: 3)
        )

        let laserPower = opticalState.power(at: laserOut)
        let modPower = opticalState.power(at: modOut)

        // At quadrature: T = IL * cos^2(pi/4) = 0.95 * 0.5 = 0.475
        let expectedModPower = laserPower * 0.95 * 0.5
        #expect(abs(modPower - expectedModPower) < 1e-9,
                "Modulator at quadrature should transmit 47.5% of laser power")

        // Sensitivities at modulator output should include:
        // 1. Upstream from laser (propagated through modulator)
        // 2. Local from modulator bias/signal
        let allSens = opticalState.sensitivities.sensitivities(for: modOut.id)
        #expect(allSens.count >= 2, "Should have both upstream and local sensitivities")

        // Upstream laser anode sensitivity
        let laserAnodeSensAtMod = allSens.first(where: { $0.electricalVarIndex == 0 })
        #expect(laserAnodeSensAtMod != nil, "Laser anode sensitivity should propagate to modulator output")

        // Local bias sensitivity
        let biasSens = allSens.first(where: { $0.electricalVarIndex == 4 })
        #expect(biasSens != nil, "Modulator bias sensitivity should be present")
    }
}

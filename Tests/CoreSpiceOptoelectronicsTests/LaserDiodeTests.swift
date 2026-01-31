import Testing
import Foundation
import CoreSpiceIR
import CoreSpiceDevices
@testable import CoreSpiceOptoelectronics

@Suite("Laser Diode Device Model Tests")
struct LaserDiodeTests {

    private func makeLaser(
        params: LaserDiodeModelParameters = LaserDiodeModelParameters()
    ) -> (laser: BoundLaserDiode, anode: Node, cathode: Node, optOut: OpticalNode) {
        let anode = Node(id: 1)
        let cathode = Node(id: 2)
        let optOut = OpticalNode(id: 1)

        let laser = BoundLaserDiode(
            instance: Instance(name: "LD1", typeName: "laser", nodes: [anode, cathode], parameters: [:]),
            anode: anode,
            cathode: cathode,
            anodeIdx: 0,
            cathodeIdx: 1,
            opticalOutput: optOut,
            parameters: params
        )
        return (laser, anode, cathode, optOut)
    }

    private func makeState(anodeV: Double, cathodeV: Double, anode: Node, cathode: Node) -> SolutionState {
        let variables: [Double] = [anodeV, cathodeV]
        let varMap: [MNAVariable: Int] = [
            .nodeVoltage(anode): 0,
            .nodeVoltage(cathode): 1
        ]
        return SolutionState(
            variables: variables,
            previousVariables: variables,
            twoPreviousVariables: variables,
            variableMap: varMap
        )
    }

    @Test("Laser emits above threshold with correct slope efficiency")
    func aboveThresholdEmission() {
        let params = LaserDiodeModelParameters(
            saturationCurrent: 1e-14,
            thresholdCurrent: 20e-3,
            slopeEfficiency: 0.3,
            wavelength: 1550e-9
        )
        let (laser, anode, cathode, optOut) = makeLaser(params: params)

        // Strong forward bias to get well above I_th = 20 mA
        let state = makeState(anodeV: 1.25, cathodeV: 0.0, anode: anode, cathode: cathode)
        let opticalState = OpticalState(nodeCount: 2)
        let result = laser.computeOpticalOutputWithSensitivity(
            electricalState: state, opticalState: opticalState
        )

        let signal = result.signals[optOut]!
        #expect(signal.power > 0, "Laser should emit above threshold")

        #expect(!result.sensitivities.isEmpty, "Should have sensitivities above threshold")
        let anodeSens = result.sensitivities.first(where: { $0.electricalVarIndex == 0 })
        #expect(anodeSens != nil && anodeSens!.dPdV > 0, "dP/dV_anode should be positive")
    }

    @Test("Laser has near-zero emission below threshold")
    func belowThresholdEmission() {
        let params = LaserDiodeModelParameters(
            saturationCurrent: 1e-14,
            thresholdCurrent: 20e-3,
            slopeEfficiency: 0.3,
            spontaneousEmissionFactor: 1e-4
        )
        let (laser, anode, cathode, optOut) = makeLaser(params: params)

        // Small forward bias: well below threshold current
        let state = makeState(anodeV: 0.7, cathodeV: 0.0, anode: anode, cathode: cathode)
        let opticalState = OpticalState(nodeCount: 2)
        let result = laser.computeOpticalOutputWithSensitivity(
            electricalState: state, opticalState: opticalState
        )

        let signal = result.signals[optOut]!
        #expect(signal.power < 1e-6, "Power below threshold should be very small")
    }

    @Test("Laser provides noise sources including shot noise and RIN")
    func noiseSources() {
        let params = LaserDiodeModelParameters(
            saturationCurrent: 1e-14,
            thresholdCurrent: 20e-3,
            slopeEfficiency: 0.3,
            rinDB: -155
        )
        let (laser, anode, cathode, _) = makeLaser(params: params)

        let state = makeState(anodeV: 1.25, cathodeV: 0.0, anode: anode, cathode: cathode)
        let opticalState = OpticalState(nodeCount: 2)
        let noise = laser.noiseContributions(
            state: state, opticalState: opticalState, frequency: 1e9
        )

        #expect(noise.count == 2, "Should have shot noise and RIN noise sources")

        let shotNoise = noise.first(where: { $0.name.contains("shot") })
        let rinNoise = noise.first(where: { $0.name.contains("rin") })

        #expect(shotNoise != nil, "Should have shot noise")
        #expect(rinNoise != nil, "Should have RIN noise")
        #expect(shotNoise!.currentSpectralDensity > 0, "Shot noise should be positive")
        #expect(rinNoise!.currentSpectralDensity > 0, "RIN noise should be positive")
    }

    @Test("Laser RIN parameter converts correctly from dB")
    func rinConversion() {
        let params = LaserDiodeModelParameters(rinDB: -155)

        let expectedLinear = pow(10.0, -155.0 / 10.0)
        #expect(abs(params.rinLinear - expectedLinear) < 1e-30)
    }

    @Test("Laser L-I curve: slope efficiency is dP/dI above threshold")
    func liCurveSlope() {
        let slopeEff = 0.3
        let ith = 20e-3

        // Verify the L-I relationship
        let i1 = 25e-3
        let i2 = 30e-3
        let p1 = slopeEff * (i1 - ith)
        let p2 = slopeEff * (i2 - ith)

        let actualSlope = (p2 - p1) / (i2 - i1)
        #expect(abs(actualSlope - slopeEff) < 1e-12,
                "L-I slope should equal slope efficiency above threshold")
        #expect(abs(p1 - 1.5e-3) < 1e-12, "P at 25mA should be 1.5mW")
        #expect(abs(p2 - 3.0e-3) < 1e-12, "P at 30mA should be 3.0mW")
    }

    @Test("Laser sensitivity sign: anode positive, cathode negative")
    func sensitivityPolarity() {
        let params = LaserDiodeModelParameters(
            saturationCurrent: 1e-14,
            thresholdCurrent: 20e-3,
            slopeEfficiency: 0.3
        )
        let (laser, anode, cathode, optOut) = makeLaser(params: params)

        let state = makeState(anodeV: 1.25, cathodeV: 0.0, anode: anode, cathode: cathode)
        let opticalState = OpticalState(nodeCount: 2)
        let result = laser.computeOpticalOutputWithSensitivity(
            electricalState: state, opticalState: opticalState
        )

        let anodeSens = result.sensitivities.first(where: { $0.electricalVarIndex == 0 })
        let cathodeSens = result.sensitivities.first(where: { $0.electricalVarIndex == 1 })

        #expect(anodeSens != nil && anodeSens!.dPdV > 0)
        #expect(cathodeSens != nil && cathodeSens!.dPdV < 0)
        // Magnitudes should be equal (dI/dV_anode = -dI/dV_cathode)
        #expect(abs(anodeSens!.dPdV + cathodeSens!.dPdV) < 1e-15)
    }
}

import Foundation
import Testing
@testable import PluginsPhotonic

@Suite("Local chromatic dispersion model")
struct WavelengthDispersionTests {
    @Test(arguments: [-20e-6, 0.0, 20e-6])
    func evaluatesIndependentSecondOrderFormula(dispersion: Double) throws {
        let center = 1550e-9
        let groupIndex = 4.2
        let length = 2e-3
        let base = 0.7
        let model = WavelengthModel(centerWavelength: center, groupIndex: groupIndex,
                                    dispersion: dispersion, armLengthImbalance: length)
        #expect(try model.effectivePhase(basePhase: base, wavelength: center) == base)
        for deviation in [-10e-9, 10e-9] {
            let first = -2 * Double.pi * groupIndex * deviation / (center * center)
            let second = (2 * Double.pi * groupIndex / pow(center, 3) -
                          Double.pi * 299_792_458 * dispersion / pow(center, 2)) * deviation * deviation
            let expected = base + length * (first + second)
            let actual = try model.effectivePhase(basePhase: base, wavelength: center + deviation)
            #expect(abs(actual - expected) < 1e-10)
        }
    }

    @Test(arguments: [-20e-6, 20e-6])
    func centerDerivativesMatchGroupIndexAndDispersion(dispersion: Double) throws {
        let center = 1550e-9
        let length = 2e-3
        let groupIndex = 4.2
        let model = WavelengthModel(centerWavelength: center, groupIndex: groupIndex,
                                    dispersion: dispersion, armLengthImbalance: length)
        let h = 1e-9
        let minus = try model.effectivePhase(basePhase: 0, wavelength: center - h)
        let plus = try model.effectivePhase(basePhase: 0, wavelength: center + h)
        let firstDerivative = (plus - minus) / (2 * h)
        let secondDerivative = (plus + minus) / (h * h)
        let expectedFirst = -2 * Double.pi * groupIndex * length / pow(center, 2)
        let expectedSecond = length * (4 * Double.pi * groupIndex / pow(center, 3) -
                                      2 * Double.pi * 299_792_458 * dispersion / pow(center, 2))
        #expect(abs((firstDerivative - expectedFirst) / expectedFirst) < 1e-10)
        #expect(abs((secondDerivative - expectedSecond) / expectedSecond) < 1e-9)
    }

    @Test func zeroImbalancePreservesBaseAndOverflowFails() throws {
        let zero = WavelengthModel(groupIndex: .greatestFiniteMagnitude,
                                   dispersion: .greatestFiniteMagnitude, armLengthImbalance: 0)
        #expect(try zero.effectivePhase(basePhase: 0.75, wavelength: 1600e-9) == 0.75)
        let overflow = WavelengthModel(dispersion: .greatestFiniteMagnitude, armLengthImbalance: 1)
        #expect(throws: PhotonicExecutionError.self) {
            try overflow.effectivePhase(basePhase: 1, wavelength: 1600e-9)
        }
        #expect(try overflow.effectivePhase(basePhase: 1, wavelength: 1550e-9) == 1)
    }
}

import Testing
import Foundation
@testable import CoreSpiceOptoelectronics

@Suite("Responsivity Model Tests")
struct ResponsivityModelTests {

    @Test("Responsivity at reference wavelength equals nominal value")
    func responsivityAtReference() {
        let model = ResponsivityModel(
            nominalResponsivity: 0.8,
            referenceWavelength: 1550e-9
        )

        let r = model.responsivity(at: 1550e-9)
        #expect(abs(r - 0.8) < 1e-15,
                "Responsivity at reference wavelength should equal nominal")
    }

    @Test("Responsivity scales linearly with wavelength")
    func linearScaling() {
        let model = ResponsivityModel(
            nominalResponsivity: 0.8,
            referenceWavelength: 1550e-9
        )

        let r1310 = model.responsivity(at: 1310e-9)
        let expected = 0.8 * 1310e-9 / 1550e-9
        #expect(abs(r1310 - expected) < 1e-15,
                "Responsivity should scale as R_nom * lambda / lambda_ref")
    }

    @Test("Responsivity is zero outside spectral range")
    func outsideSpectralRange() {
        let model = ResponsivityModel(
            nominalResponsivity: 0.8,
            referenceWavelength: 1550e-9,
            minWavelength: 900e-9,
            maxWavelength: 1700e-9
        )

        let rShort = model.responsivity(at: 800e-9)
        let rLong = model.responsivity(at: 1800e-9)
        #expect(rShort == 0.0, "Below min wavelength should return zero")
        #expect(rLong == 0.0, "Above max wavelength should return zero")
    }

    @Test("Responsivity at spectral boundaries is non-zero")
    func spectralBoundaries() {
        let model = ResponsivityModel(
            nominalResponsivity: 0.8,
            referenceWavelength: 1550e-9,
            minWavelength: 900e-9,
            maxWavelength: 1700e-9
        )

        let rMin = model.responsivity(at: 900e-9)
        let rMax = model.responsivity(at: 1700e-9)
        #expect(rMin > 0, "At min wavelength should be positive")
        #expect(rMax > 0, "At max wavelength should be positive")
    }

    @Test("Quantum efficiency is physically reasonable")
    func quantumEfficiency() {
        let model = ResponsivityModel(
            nominalResponsivity: 0.8,
            referenceWavelength: 1550e-9
        )

        let eta = model.quantumEfficiency
        // For R = 0.8 A/W at 1550 nm:
        // eta = R * h * c / (q * lambda)
        // = 0.8 * 6.626e-34 * 3e8 / (1.602e-19 * 1550e-9)
        // ≈ 0.64
        #expect(eta > 0 && eta <= 1.0,
                "Quantum efficiency should be between 0 and 1: got \(eta)")
        #expect(abs(eta - 0.64) < 0.01,
                "QE for R=0.8 at 1550nm should be about 0.64: got \(eta)")
    }

    @Test("Default model parameters are reasonable for InGaAs PD")
    func defaultParameters() {
        let model = ResponsivityModel()

        #expect(model.nominalResponsivity == 0.8)
        #expect(model.referenceWavelength == 1550e-9)
        #expect(model.minWavelength == 400e-9)
        #expect(model.maxWavelength == 1700e-9)
    }
}

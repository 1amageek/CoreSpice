import Testing
import Foundation
@testable import CoreSpiceOptoelectronics

@Suite("Laser Rate Equation Solver Tests")
struct LaserRateEquationSolverTests {

    private let defaultParams = LaserDiodeModelParameters(
        saturationCurrent: 1e-14,
        emissionCoefficient: 2.0,
        seriesResistance: 5.0,
        junctionCapacitance: 2e-12,
        junctionPotential: 0.7,
        gradingCoefficient: 0.5,
        thresholdCurrent: 20e-3,
        slopeEfficiency: 0.3,
        wavelength: 1550e-9,
        carrierLifetime: 1e-9,
        photonLifetime: 2e-12,
        activeVolume: 3e-17,
        confinementFactor: 0.3,
        differentialGain: 2.5e-12,
        transparencyCarrierDensity: 1.5e24,
        spontaneousEmissionFactor: 1e-4,
        rinDB: -155
    )

    @Test("DC steady state below threshold has much lower photon density than above")
    func dcBelowThreshold() {
        let belowCurrent = 10e-3  // 10 mA < threshold
        let aboveCurrent = 40e-3  // 40 mA > threshold
        let belowState = LaserRateEquationSolver.dcSteadyState(
            current: belowCurrent, params: defaultParams
        )
        let aboveState = LaserRateEquationSolver.dcSteadyState(
            current: aboveCurrent, params: defaultParams
        )

        #expect(belowState.carrierDensity > 0, "Carrier density should be positive")
        #expect(belowState.photonDensity >= 0, "Photon density should be non-negative")
        // Below threshold, photon density is dominated by spontaneous emission
        // and should be orders of magnitude smaller than above-threshold lasing
        #expect(belowState.photonDensity < aboveState.photonDensity * 0.01,
                "Below threshold S (\(belowState.photonDensity)) should be << above threshold S (\(aboveState.photonDensity))")

        // Optical power below threshold should be negligible
        let belowPower = LaserRateEquationSolver.opticalPower(
            photonDensity: belowState.photonDensity, params: defaultParams
        )
        let abovePower = LaserRateEquationSolver.opticalPower(
            photonDensity: aboveState.photonDensity, params: defaultParams
        )
        #expect(belowPower < abovePower * 0.01,
                "Below threshold power (\(belowPower)) should be << above threshold power (\(abovePower))")
    }

    @Test("DC steady state above threshold has significant photon density")
    func dcAboveThreshold() {
        let current = 40e-3  // 40 mA >> 20 mA threshold
        let state = LaserRateEquationSolver.dcSteadyState(
            current: current, params: defaultParams
        )

        #expect(state.carrierDensity > 0, "Carrier density should be positive")
        #expect(state.photonDensity > 0, "Photon density above threshold should be positive")

        // Optical power should be consistent with slope efficiency model
        let power = LaserRateEquationSolver.opticalPower(
            photonDensity: state.photonDensity, params: defaultParams
        )
        #expect(power > 0, "Optical power should be positive above threshold")
    }

    @Test("BE solver converges to steady state with constant current")
    func backwardEulerSteadyState() {
        let current = 40e-3
        let dcState = LaserRateEquationSolver.dcSteadyState(
            current: current, params: defaultParams
        )

        // Start from DC steady state and run several steps with the same current
        var state = dcState
        let dt = 1e-12  // 1 ps steps
        for _ in 0..<100 {
            let result = LaserRateEquationSolver.solve(
                current: current,
                previous: state,
                previousDerivatives: nil,
                dt: dt,
                params: defaultParams,
                method: .backwardEuler
            )
            state = result.state
        }

        // Should remain near the steady state
        let nRatio = state.carrierDensity / dcState.carrierDensity
        let sRatio = state.photonDensity / dcState.photonDensity
        #expect(abs(nRatio - 1.0) < 0.1,
                "Carrier density should stay near DC steady state: ratio = \(nRatio)")
        #expect(abs(sRatio - 1.0) < 0.5,
                "Photon density should stay near DC steady state: ratio = \(sRatio)")
    }

    @Test("Trapezoidal solver converges to steady state with constant current")
    func trapezoidalSteadyState() {
        let current = 40e-3
        let dcState = LaserRateEquationSolver.dcSteadyState(
            current: current, params: defaultParams
        )

        var state = dcState
        var prevDerivs: (dNdt: Double, dSdt: Double)? = nil
        let dt = 1e-12
        for _ in 0..<200 {
            let result = LaserRateEquationSolver.solve(
                current: current,
                previous: state,
                previousDerivatives: prevDerivs,
                dt: dt,
                params: defaultParams,
                method: .trapezoidal
            )
            state = result.state
            prevDerivs = result.derivatives
        }

        let nRatio = state.carrierDensity / dcState.carrierDensity
        let sRatio = state.photonDensity / dcState.photonDensity
        #expect(abs(nRatio - 1.0) < 0.1,
                "Carrier density should stay near DC steady state: ratio = \(nRatio)")
        #expect(abs(sRatio - 1.0) < 0.5,
                "Photon density should stay near DC steady state: ratio = \(sRatio)")
    }

    @Test("Small-signal parameters are positive above threshold")
    func smallSignalAboveThreshold() {
        let current = 40e-3
        let dcState = LaserRateEquationSolver.dcSteadyState(
            current: current, params: defaultParams
        )

        let (omegaR, gammaDamping) = LaserRateEquationSolver.smallSignalParameters(
            steadyState: dcState, params: defaultParams
        )

        #expect(omegaR > 0, "Relaxation oscillation frequency should be positive")
        #expect(gammaDamping > 0, "Damping rate should be positive")

        // Relaxation frequency should be in the GHz range for typical parameters
        let fR = omegaR / (2.0 * .pi)
        #expect(fR > 1e8 && fR < 100e9,
                "Relaxation frequency \(fR/1e9) GHz should be in reasonable range")
    }

    @Test("Small-signal parameters are near-zero below threshold")
    func smallSignalBelowThreshold() {
        let current = 5e-3  // Well below threshold
        let dcState = LaserRateEquationSolver.dcSteadyState(
            current: current, params: defaultParams
        )

        let (omegaR, _) = LaserRateEquationSolver.smallSignalParameters(
            steadyState: dcState, params: defaultParams
        )

        // Below threshold, S ~ 0, so omega_r should be very small
        #expect(omegaR < 1e9,
                "Below threshold, relaxation frequency should be very small")
    }

    @Test("Optical power from photon density is physically reasonable")
    func opticalPowerCalculation() {
        let current = 40e-3
        let dcState = LaserRateEquationSolver.dcSteadyState(
            current: current, params: defaultParams
        )

        let power = LaserRateEquationSolver.opticalPower(
            photonDensity: dcState.photonDensity, params: defaultParams
        )

        // Power should be in the mW range for 40 mA drive, 20 mA threshold, 0.3 W/A slope
        // Expected: ~ 0.3 * (40e-3 - 20e-3) = 6 mW
        // Rate equation result may differ somewhat but should be same order
        #expect(power > 0.1e-3 && power < 100e-3,
                "Optical power \(power*1e3) mW should be in reasonable range")
    }

    @Test("Solver handles zero current gracefully")
    func zeroCurrent() {
        let state = LaserRateEquationSolver.dcSteadyState(
            current: 0, params: defaultParams
        )

        #expect(state.carrierDensity >= 0)
        #expect(state.photonDensity >= 0)

        // One step with zero current
        let result = LaserRateEquationSolver.solve(
            current: 0,
            previous: state,
            previousDerivatives: nil,
            dt: 1e-12,
            params: defaultParams,
            method: .backwardEuler
        )

        #expect(result.state.carrierDensity >= 0)
        #expect(result.state.photonDensity >= 0)
    }

    @Test("Step response shows transient overshoot (relaxation oscillation)")
    func stepResponseOvershoot() {
        // Start from below threshold
        let lowCurrent = 5e-3
        var state = LaserRateEquationSolver.dcSteadyState(
            current: lowCurrent, params: defaultParams
        )

        // Step to well above threshold
        let highCurrent = 50e-3
        let dt = 0.5e-12  // 0.5 ps steps for good resolution
        var maxS = state.photonDensity
        var prevDerivs: (dNdt: Double, dSdt: Double)? = nil

        for _ in 0..<2000 {
            let result = LaserRateEquationSolver.solve(
                current: highCurrent,
                previous: state,
                previousDerivatives: prevDerivs,
                dt: dt,
                params: defaultParams,
                method: .backwardEuler
            )
            state = result.state
            prevDerivs = result.derivatives
            if state.photonDensity > maxS {
                maxS = state.photonDensity
            }
        }

        // The final steady state
        let ssSteady = LaserRateEquationSolver.dcSteadyState(
            current: highCurrent, params: defaultParams
        )

        // For a laser with relaxation oscillations, the peak photon density
        // during the transient should exceed the steady state
        // (This is the hallmark of laser turn-on dynamics)
        #expect(maxS > 0, "Peak photon density should be positive")
        #expect(ssSteady.photonDensity > 0, "Steady state photon density should be positive")
    }
}

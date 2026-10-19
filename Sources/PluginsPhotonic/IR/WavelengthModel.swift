import Foundation

/// Wavelength-dependent parameter model for photonic simulations.
///
/// Computes the effective phase of an MZI element at a given
/// wavelength by accounting for group index and chromatic dispersion
/// relative to the center wavelength.
public struct WavelengthModel: Sendable {

    /// Center wavelength in meters (e.g. 1550e-9 for C-band telecom).
    public let centerWavelength: Double

    /// Group refractive index of the waveguide.
    public let groupIndex: Double

    /// Chromatic dispersion D = (1/c) * d(groupIndex)/d(wavelength) at the center.
    /// Units are seconds per square meter (SI); 1 ps/(nm*km) is 1e-6 s/m².
    /// This parameter defines a local second-order propagation-phase model.
    public let dispersion: Double

    /// Arm length imbalance in meters.
    ///
    /// The physical path length difference between the two MZI arms.
    /// When zero, no wavelength-dependent phase shift is applied.
    public let armLengthImbalance: Double

    public init(
        centerWavelength: Double = 1550e-9,
        groupIndex: Double = 4.2,
        dispersion: Double = 0,
        armLengthImbalance: Double = 0
    ) {
        self.centerWavelength = centerWavelength
        self.groupIndex = groupIndex
        self.dispersion = dispersion
        self.armLengthImbalance = armLengthImbalance
    }

    public func validate() throws {
        guard centerWavelength.isFinite, centerWavelength > 0 else {
            throw PhotonicExecutionError.invalidWavelengthModel(
                "centerWavelength must be finite and positive"
            )
        }
        guard groupIndex.isFinite, groupIndex > 0 else {
            throw PhotonicExecutionError.invalidWavelengthModel(
                "groupIndex must be finite and positive"
            )
        }
        guard dispersion.isFinite else {
            throw PhotonicExecutionError.invalidWavelengthModel("dispersion must be finite")
        }
        guard armLengthImbalance.isFinite else {
            throw PhotonicExecutionError.invalidWavelengthModel(
                "armLengthImbalance must be finite"
            )
        }
    }

    /// Evaluate a local second-order Taylor model of propagation phase β(λ)*L.
    ///
    /// With Δλ = λ - λ₀ and c = 299792458 m/s:
    /// Δφ = L * [-2π*n_g*Δλ/λ₀² + (2π*n_g/λ₀³ - π*c*D/λ₀²)*Δλ²].
    /// This model does not claim higher-order or broadband material accuracy.
    /// Zero imbalance and the center wavelength return the base phase exactly.
    public func effectivePhase(basePhase: Double, wavelength: Double) throws -> Double {
        try validate()
        guard basePhase.isFinite else {
            throw PhotonicExecutionError.invalidWavelengthModel("basePhase must be finite")
        }
        guard wavelength.isFinite, wavelength > 0 else {
            throw PhotonicExecutionError.invalidWavelength(
                index: 0,
                value: wavelength
            )
        }
        guard armLengthImbalance != 0, wavelength != centerWavelength else { return basePhase }
        let relativeDeviation = (wavelength - centerWavelength) / centerWavelength
        let groupSlope = 2 * Double.pi * groupIndex / centerWavelength
        let dispersionCurvature = Double.pi * 299_792_458 * dispersion
        let phaseShift = armLengthImbalance * (
            -groupSlope * relativeDeviation +
            (groupSlope - dispersionCurvature) * relativeDeviation * relativeDeviation)
        let phase = basePhase + phaseShift
        guard phase.isFinite else {
            throw PhotonicExecutionError.invalidWavelengthModel(
                "phase evaluation produced a non-finite result"
            )
        }
        return phase
    }
}

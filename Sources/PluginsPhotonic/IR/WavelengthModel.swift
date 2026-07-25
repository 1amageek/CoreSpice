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

    /// Chromatic dispersion coefficient.
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

    /// Computes the effective phase at a specific wavelength.
    ///
    /// The phase shift due to wavelength deviation is:
    /// `Δφ = -2π · n_g · ΔΛ · L / λ₀²`
    ///
    /// The negative sign reflects that increasing wavelength decreases
    /// the effective refractive index, reducing the accumulated phase.
    ///
    /// - Parameters:
    ///   - basePhase: The nominal phase at center wavelength (radians).
    ///   - wavelength: The actual operating wavelength (meters).
    /// - Returns: Adjusted phase accounting for group index shift.
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

    public func effectivePhase(basePhase: Double, wavelength: Double) throws -> Double {
        try validate()
        guard basePhase.isFinite, wavelength.isFinite, wavelength > 0 else {
            throw PhotonicExecutionError.invalidWavelength(
                index: 0,
                value: wavelength
            )
        }
        let deltaLambda = wavelength - centerWavelength
        let phaseShift = -2.0 * .pi * groupIndex * deltaLambda * armLengthImbalance / (centerWavelength * centerWavelength)
        let phase = basePhase + phaseShift
        guard phase.isFinite else {
            throw PhotonicExecutionError.invalidWavelengthModel(
                "phase evaluation produced a non-finite result"
            )
        }
        return phase
    }
}

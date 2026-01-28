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

    public init(
        centerWavelength: Double = 1550e-9,
        groupIndex: Double = 4.2,
        dispersion: Double = 0
    ) {
        self.centerWavelength = centerWavelength
        self.groupIndex = groupIndex
        self.dispersion = dispersion
    }

    /// Computes the effective phase at a specific wavelength.
    ///
    /// - Parameters:
    ///   - basePhase: The nominal phase at center wavelength (radians).
    ///   - wavelength: The actual operating wavelength (meters).
    /// - Returns: Adjusted phase accounting for group index shift.
    public func effectivePhase(basePhase: Double, wavelength: Double) -> Double {
        let deltaLambda = wavelength - centerWavelength
        let phaseShift = 2.0 * .pi * groupIndex * deltaLambda / (centerWavelength * centerWavelength)
        return basePhase + phaseShift
    }
}

import Foundation

/// Wavelength-dependent responsivity model for photodetectors.
///
/// The responsivity `R(λ)` of a photodiode relates the photocurrent
/// to the incident optical power:
///   `I_photo = R(λ) * P_optical`
///
/// The model scales the nominal responsivity by the ratio of
/// actual wavelength to reference wavelength, clamped within the
/// device's spectral response range.
///
/// Physical basis:
///   `R(λ) = η * q * λ / (h * c)`
/// where `η` is quantum efficiency, `q` is electron charge,
/// `h` is Planck's constant, `c` is speed of light.
/// At a fixed quantum efficiency, `R ∝ λ`.
public struct ResponsivityModel: Sendable {

    /// Nominal responsivity at reference wavelength (A/W).
    public let nominalResponsivity: Double

    /// Reference wavelength (m) at which nominal responsivity is specified.
    public let referenceWavelength: Double

    /// Minimum wavelength of spectral response (m). Default: 400 nm.
    public let minWavelength: Double

    /// Maximum wavelength of spectral response (m). Default: 1700 nm.
    public let maxWavelength: Double

    public init(
        nominalResponsivity: Double = 0.8,
        referenceWavelength: Double = 1550e-9,
        minWavelength: Double = 400e-9,
        maxWavelength: Double = 1700e-9
    ) {
        self.nominalResponsivity = nominalResponsivity
        self.referenceWavelength = referenceWavelength
        self.minWavelength = minWavelength
        self.maxWavelength = maxWavelength
    }

    /// Computes responsivity at a given wavelength.
    ///
    /// Returns `R_nom * (λ / λ_ref)` clamped to the spectral range.
    /// Outside the range, returns zero.
    public func responsivity(at wavelength: Double) -> Double {
        guard wavelength >= minWavelength, wavelength <= maxWavelength else {
            return 0.0
        }
        return nominalResponsivity * wavelength / referenceWavelength
    }

    /// Quantum efficiency implied by the nominal responsivity.
    ///
    /// `η = R * h * c / (q * λ)`
    public var quantumEfficiency: Double {
        let h = 6.62607015e-34
        let c = 299792458.0
        let q = 1.602176634e-19
        return nominalResponsivity * h * c / (q * referenceWavelength)
    }
}

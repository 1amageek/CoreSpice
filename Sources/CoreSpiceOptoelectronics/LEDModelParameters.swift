import Foundation

/// Model parameters for a light-emitting diode (LED).
///
/// The electrical model is a standard PN junction (Shockley diode).
/// The optical model emits power proportional to the forward current:
///   `P_out = eta_ext * I_fwd * h*nu/q`
///
/// where `h*nu/q` is the photon energy per electron charge at the peak wavelength.
public struct LEDModelParameters: Sendable {

    // MARK: - PN Junction Parameters

    /// Saturation current (A). Default: 1e-14 A.
    public var saturationCurrent: Double

    /// Emission coefficient (ideality factor). Default: 2.0 (radiative recombination).
    public var emissionCoefficient: Double

    /// Ohmic series resistance (ohm). Default: 5 ohm.
    public var seriesResistance: Double

    /// Zero-bias junction capacitance (F). Default: 10 pF.
    public var junctionCapacitance: Double

    /// Built-in junction potential (V). Default: 0.7 V.
    public var junctionPotential: Double

    /// Grading coefficient. Default: 0.5.
    public var gradingCoefficient: Double

    // MARK: - Optical Parameters

    /// External quantum efficiency (dimensionless, 0..1). Default: 0.1 (10%).
    public var externalQuantumEfficiency: Double

    /// Peak emission wavelength (m). Default: 850 nm.
    public var peakWavelength: Double

    /// Radiative recombination time constant (s). Default: 10 ns.
    public var radiativeLifetime: Double

    /// Nominal temperature (K). Default: 300.15 K.
    public var nominalTemperature: Double

    public init(
        saturationCurrent: Double = 1e-14,
        emissionCoefficient: Double = 2.0,
        seriesResistance: Double = 5.0,
        junctionCapacitance: Double = 10e-12,
        junctionPotential: Double = 0.7,
        gradingCoefficient: Double = 0.5,
        externalQuantumEfficiency: Double = 0.1,
        peakWavelength: Double = 850e-9,
        radiativeLifetime: Double = 10e-9,
        nominalTemperature: Double = 300.15
    ) {
        self.saturationCurrent = saturationCurrent
        self.emissionCoefficient = emissionCoefficient
        self.seriesResistance = seriesResistance
        self.junctionCapacitance = junctionCapacitance
        self.junctionPotential = junctionPotential
        self.gradingCoefficient = gradingCoefficient
        self.externalQuantumEfficiency = externalQuantumEfficiency
        self.peakWavelength = peakWavelength
        self.radiativeLifetime = radiativeLifetime
        self.nominalTemperature = nominalTemperature
    }

    /// Thermal voltage at nominal temperature (kT/q).
    public var thermalVoltage: Double {
        let k = 1.380649e-23
        let q = 1.602176634e-19
        return k * nominalTemperature / q
    }

    /// Photon energy at peak wavelength: h*c/lambda (J).
    public var photonEnergy: Double {
        let h = 6.62607015e-34
        let c = 299792458.0
        return h * c / peakWavelength
    }

    /// Conversion factor: optical power per unit forward current (W/A).
    /// `P = factor * I_fwd` where `factor = eta_ext * h*nu / q`.
    public var powerPerCurrent: Double {
        let q = 1.602176634e-19
        return externalQuantumEfficiency * photonEnergy / q
    }
}

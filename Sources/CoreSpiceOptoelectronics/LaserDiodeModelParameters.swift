import Foundation

/// Model parameters for a Fabry-Perot or single-mode laser diode.
///
/// DC model: Above threshold, `P = slope_efficiency * (I - I_th)`.
/// Transient model: Rate equations for carrier density N and photon density S.
/// AC model: Small-signal transfer function with relaxation oscillation.
public struct LaserDiodeModelParameters: Sendable {

    // MARK: - PN Junction (Electrical)

    /// Saturation current (A). Default: 1e-14 A.
    public var saturationCurrent: Double

    /// Emission coefficient. Default: 2.0.
    public var emissionCoefficient: Double

    /// Ohmic series resistance (ohm). Default: 5 ohm.
    public var seriesResistance: Double

    /// Zero-bias junction capacitance (F). Default: 2 pF.
    public var junctionCapacitance: Double

    /// Built-in junction potential (V). Default: 0.7 V.
    public var junctionPotential: Double

    /// Grading coefficient. Default: 0.5.
    public var gradingCoefficient: Double

    // MARK: - Laser Optical Parameters

    /// Threshold current (A). Default: 20 mA.
    public var thresholdCurrent: Double

    /// Slope efficiency (W/A) above threshold. Default: 0.3 W/A.
    public var slopeEfficiency: Double

    /// Lasing wavelength (m). Default: 1550 nm.
    public var wavelength: Double

    // MARK: - Rate Equation Parameters (Transient)

    /// Carrier lifetime (s). Default: 1 ns.
    public var carrierLifetime: Double

    /// Photon lifetime (s). Default: 2 ps.
    public var photonLifetime: Double

    /// Active region volume (m^3). Default: 3e-17 m^3 (300 um x 1 um x 0.1 um).
    public var activeVolume: Double

    /// Optical confinement factor. Default: 0.3.
    public var confinementFactor: Double

    /// Volumetric differential gain coefficient (m³/s).
    /// This is `v_g * a` where `v_g` is the group velocity and `a` is the
    /// differential gain cross-section. Default: 2.5e-12 m³/s
    /// (corresponding to `a ≈ 2.5e-20 m²` and `v_g ≈ c/3.5 ≈ 8.6e7 m/s`).
    public var differentialGain: Double

    /// Transparency carrier density (1/m^3). Default: 1.5e24.
    public var transparencyCarrierDensity: Double

    /// Spontaneous emission coupling factor. Default: 1e-4.
    public var spontaneousEmissionFactor: Double

    // MARK: - Noise

    /// Relative intensity noise (dB/Hz). Default: -155 dBc/Hz.
    public var rinDB: Double

    // MARK: - Temperature

    /// Nominal temperature (K). Default: 300.15 K.
    public var nominalTemperature: Double

    /// Characteristic temperature for threshold current (K). Default: 50 K.
    public var characteristicTemperature: Double

    public init(
        saturationCurrent: Double = 1e-14,
        emissionCoefficient: Double = 2.0,
        seriesResistance: Double = 5.0,
        junctionCapacitance: Double = 2e-12,
        junctionPotential: Double = 0.7,
        gradingCoefficient: Double = 0.5,
        thresholdCurrent: Double = 20e-3,
        slopeEfficiency: Double = 0.3,
        wavelength: Double = 1550e-9,
        carrierLifetime: Double = 1e-9,
        photonLifetime: Double = 2e-12,
        activeVolume: Double = 3e-17,
        confinementFactor: Double = 0.3,
        differentialGain: Double = 2.5e-12,
        transparencyCarrierDensity: Double = 1.5e24,
        spontaneousEmissionFactor: Double = 1e-4,
        rinDB: Double = -155,
        nominalTemperature: Double = 300.15,
        characteristicTemperature: Double = 50.0
    ) {
        self.saturationCurrent = saturationCurrent
        self.emissionCoefficient = emissionCoefficient
        self.seriesResistance = seriesResistance
        self.junctionCapacitance = junctionCapacitance
        self.junctionPotential = junctionPotential
        self.gradingCoefficient = gradingCoefficient
        self.thresholdCurrent = thresholdCurrent
        self.slopeEfficiency = slopeEfficiency
        self.wavelength = wavelength
        self.carrierLifetime = carrierLifetime
        self.photonLifetime = photonLifetime
        self.activeVolume = activeVolume
        self.confinementFactor = confinementFactor
        self.differentialGain = differentialGain
        self.transparencyCarrierDensity = transparencyCarrierDensity
        self.spontaneousEmissionFactor = spontaneousEmissionFactor
        self.rinDB = rinDB
        self.nominalTemperature = nominalTemperature
        self.characteristicTemperature = characteristicTemperature
    }

    /// Thermal voltage at nominal temperature (kT/q).
    public var thermalVoltage: Double {
        let k = 1.380649e-23
        let q = 1.602176634e-19
        return k * nominalTemperature / q
    }

    /// RIN as a linear power ratio (from dB/Hz).
    public var rinLinear: Double {
        pow(10.0, rinDB / 10.0)
    }
}

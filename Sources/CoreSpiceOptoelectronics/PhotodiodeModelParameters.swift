import Foundation

/// Model parameters for a PIN/PN photodiode.
///
/// Combines standard PN junction parameters (Shockley diode) with
/// optical receiver parameters (responsivity, dark current).
///
/// The electrical model is identical to a standard diode; the optical
/// model adds a photocurrent proportional to incident optical power.
public struct PhotodiodeModelParameters: Sendable {

    // MARK: - PN Junction Parameters

    /// Saturation current (A). Default: 1e-14 A.
    public var saturationCurrent: Double

    /// Emission coefficient (ideality factor). Default: 1.0.
    public var emissionCoefficient: Double

    /// Ohmic series resistance (ohm). Default: 0.
    public var seriesResistance: Double

    /// Reverse breakdown voltage (V). Default: infinity.
    public var breakdownVoltage: Double

    /// Current at breakdown voltage (A). Default: 1e-3 A.
    public var breakdownCurrent: Double

    /// Zero-bias junction capacitance (F). Default: 0.5 pF.
    public var junctionCapacitance: Double

    /// Built-in junction potential (V). Default: 0.7 V.
    public var junctionPotential: Double

    /// Grading coefficient. Default: 0.5.
    public var gradingCoefficient: Double

    /// Forward transit time (s). Default: 0.
    public var transitTime: Double

    // MARK: - Optical Parameters

    /// Responsivity at reference wavelength (A/W). Default: 0.8.
    public var responsivity: Double

    /// Reference wavelength for responsivity (m). Default: 1550 nm.
    public var referenceWavelength: Double

    /// Dark current (A). Default: 1e-9 A (1 nA).
    public var darkCurrent: Double

    /// Nominal temperature (K). Default: 300.15 K (27 C).
    public var nominalTemperature: Double

    public init(
        saturationCurrent: Double = 1e-14,
        emissionCoefficient: Double = 1.0,
        seriesResistance: Double = 0.0,
        breakdownVoltage: Double = .infinity,
        breakdownCurrent: Double = 1e-3,
        junctionCapacitance: Double = 0.5e-12,
        junctionPotential: Double = 0.7,
        gradingCoefficient: Double = 0.5,
        transitTime: Double = 0.0,
        responsivity: Double = 0.8,
        referenceWavelength: Double = 1550e-9,
        darkCurrent: Double = 1e-9,
        nominalTemperature: Double = 300.15
    ) {
        self.saturationCurrent = saturationCurrent
        self.emissionCoefficient = emissionCoefficient
        self.seriesResistance = seriesResistance
        self.breakdownVoltage = breakdownVoltage
        self.breakdownCurrent = breakdownCurrent
        self.junctionCapacitance = junctionCapacitance
        self.junctionPotential = junctionPotential
        self.gradingCoefficient = gradingCoefficient
        self.transitTime = transitTime
        self.responsivity = responsivity
        self.referenceWavelength = referenceWavelength
        self.darkCurrent = darkCurrent
        self.nominalTemperature = nominalTemperature
    }

    /// Thermal voltage at nominal temperature (kT/q).
    public var thermalVoltage: Double {
        let k = 1.380649e-23
        let q = 1.602176634e-19
        return k * nominalTemperature / q
    }
}

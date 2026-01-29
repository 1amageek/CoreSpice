import Foundation

/// Model parameters for a PN junction diode.
///
/// These parameters follow the SPICE diode model conventions and support
/// the Shockley equation with reverse breakdown, junction capacitance,
/// and temperature effects.
public struct DiodeModelParameters: Sendable {

    /// Saturation current (A). Default: 1e-14 A.
    public var saturationCurrent: Double

    /// Emission coefficient (ideality factor). Default: 1.0.
    public var emissionCoefficient: Double

    /// Ohmic series resistance (Ω). Default: 0 Ω.
    public var seriesResistance: Double

    /// Reverse breakdown voltage (V). Default: infinity (no breakdown).
    public var breakdownVoltage: Double

    /// Current at breakdown voltage (A). Default: 1e-3 A.
    public var breakdownCurrent: Double

    /// Zero-bias junction capacitance (F). Default: 0 F.
    public var junctionCapacitance: Double

    /// Built-in junction potential (V). Default: 1.0 V.
    public var junctionPotential: Double

    /// Grading coefficient. Default: 0.5.
    public var gradingCoefficient: Double

    /// Forward transit time (s). Default: 0 s.
    public var transitTime: Double

    /// Energy gap (eV) for temperature modeling. Default: 1.11 eV (silicon).
    public var energyGap: Double

    /// Saturation current temperature exponent. Default: 3.0.
    public var saturationCurrentExponent: Double

    /// Nominal temperature (K). Default: 300.15 K (27°C).
    public var nominalTemperature: Double

    /// Creates default diode parameters.
    public init(
        saturationCurrent: Double = 1e-14,
        emissionCoefficient: Double = 1.0,
        seriesResistance: Double = 0.0,
        breakdownVoltage: Double = .infinity,
        breakdownCurrent: Double = 1e-3,
        junctionCapacitance: Double = 0.0,
        junctionPotential: Double = 1.0,
        gradingCoefficient: Double = 0.5,
        transitTime: Double = 0.0,
        energyGap: Double = 1.11,
        saturationCurrentExponent: Double = 3.0,
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
        self.energyGap = energyGap
        self.saturationCurrentExponent = saturationCurrentExponent
        self.nominalTemperature = nominalTemperature
    }

    /// Thermal voltage at nominal temperature (kT/q).
    public var thermalVoltage: Double {
        let k = 1.380649e-23  // Boltzmann constant (J/K)
        let q = 1.602176634e-19  // Elementary charge (C)
        return k * nominalTemperature / q
    }
}

import Foundation

/// Model parameters for a Mach-Zehnder electro-optic modulator (MZM).
///
/// Transfer function: `P_out = P_in * IL * cos^2(pi*(V_bias + V_signal) / (2*Vpi) + phi_0)`
///
/// The modulator has both electrical ports (RF signal, DC bias) and
/// optical ports (input, output).
public struct EOModulatorModelParameters: Sendable {

    /// Half-wave voltage (V). Default: 3.5 V.
    public var vPi: Double

    /// Insertion loss (linear, 0..1). Default: 0.95 (≈ 0.22 dB).
    public var insertionLoss: Double

    /// Extinction ratio (linear). Default: 30 dB → 1e-3.
    public var extinctionRatioLinear: Double

    /// Bias phase offset (radians). Default: 0.
    public var biasPhase: Double

    /// Electrode capacitance (F). Default: 0.5 pF.
    public var electrodeCapacitance: Double

    /// Electrode resistance (ohm). Default: 50 ohm.
    public var electrodeResistance: Double

    /// Electrical bandwidth (Hz). Default: 40 GHz.
    public var bandwidth: Double

    public init(
        vPi: Double = 3.5,
        insertionLoss: Double = 0.95,
        extinctionRatioLinear: Double = 1e-3,
        biasPhase: Double = 0,
        electrodeCapacitance: Double = 0.5e-12,
        electrodeResistance: Double = 50.0,
        bandwidth: Double = 40e9
    ) {
        self.vPi = vPi
        self.insertionLoss = insertionLoss
        self.extinctionRatioLinear = extinctionRatioLinear
        self.biasPhase = biasPhase
        self.electrodeCapacitance = electrodeCapacitance
        self.electrodeResistance = electrodeResistance
        self.bandwidth = bandwidth
    }
}

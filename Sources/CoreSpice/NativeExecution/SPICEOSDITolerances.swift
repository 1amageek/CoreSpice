import CoreSpiceOSDI

/// Explicit tolerances for temperature rise and power-balance rows.
public struct SPICEOSDITolerances: Sendable, Equatable {
    public let temperatureAbsoluteKelvin: Double
    public let thermalResidualAbsoluteWatts: Double
    public init(temperatureAbsoluteKelvin: Double, thermalResidualAbsoluteWatts: Double) throws(OSDIAdapterFailure) {
        guard temperatureAbsoluteKelvin.isFinite, temperatureAbsoluteKelvin > 0,
              thermalResidualAbsoluteWatts.isFinite, thermalResidualAbsoluteWatts > 0 else { throw .conditionsMismatch }
        self.temperatureAbsoluteKelvin = temperatureAbsoluteKelvin
        self.thermalResidualAbsoluteWatts = thermalResidualAbsoluteWatts
    }
}

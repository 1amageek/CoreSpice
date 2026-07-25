import CoreSpiceIR

enum MOSFETNoiseModel {
    private static let boltzmann: Double = 1.380649e-23
    private static let channelThermalFactor: Double = 2.0 / 3.0

    static func channelThermalNoiseSource(
        instanceName: String,
        positiveNode: Node,
        negativeNode: Node,
        gm: Double,
        gds: Double,
        temperatureKelvin: Double
    ) -> [NoiseSource] {
        let channelConductance = max(abs(gm) * channelThermalFactor, max(gds, 0.0))
        guard channelConductance > 0 else { return [] }

        return [
            NoiseSource(
                name: "\(instanceName)_channel_thermal",
                positiveNode: positiveNode,
                negativeNode: negativeNode,
                currentSpectralDensity: 4.0 * boltzmann * temperatureKelvin * channelConductance
            )
        ]
    }
}

public struct SPICEInstanceOperatingConditions: Sendable, Hashable {
    public let instanceName: String
    public let modelName: String?
    public let temperatureCelsius: Double
    public let nominalTemperatureCelsius: Double
    public let temperatureOrigin: String
    public let nominalTemperatureOrigin: String
}

public enum SPICEOperatingConditionPolicy: Sendable, Hashable {
    case recordActual
    case requireExactReference(temperatureCelsius: Double, supplyVoltage: Double)
}

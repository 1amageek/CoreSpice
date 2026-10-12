public enum TemperatureFailure: Error, Sendable, Equatable {
    case nonFinite
    case absoluteZeroOrBelow
    case conversionNotRepresentable
    case unsupportedIdentityVersion(UInt32)
}

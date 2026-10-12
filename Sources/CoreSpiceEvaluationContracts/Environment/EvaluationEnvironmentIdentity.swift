/// Stable semantic words; artifact digest encoding belongs to the caller.
public struct EvaluationEnvironmentIdentity: Sendable, Hashable {
    public static let currentContractVersion: UInt32 = 1
    public let contractVersion: UInt32
    public let ambientKelvinBits: UInt64
    public let nominalKelvinBits: UInt64

    public init(contractVersion: UInt32, ambientKelvinBits: UInt64,
                nominalKelvinBits: UInt64) throws(TemperatureFailure) {
        guard contractVersion == Self.currentContractVersion else {
            throw .unsupportedIdentityVersion(contractVersion)
        }
        let ambient = try TemperatureKelvin(Double(bitPattern: ambientKelvinBits))
        let nominal = try TemperatureKelvin(Double(bitPattern: nominalKelvinBits))
        self.init(ambient: ambient, nominal: nominal)
    }

    init(ambient: TemperatureKelvin, nominal: TemperatureKelvin) {
        contractVersion = Self.currentContractVersion
        ambientKelvinBits = ambient.value.bitPattern
        nominalKelvinBits = nominal.value.bitPattern
    }
}

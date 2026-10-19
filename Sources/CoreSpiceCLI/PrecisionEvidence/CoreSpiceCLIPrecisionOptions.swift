import OSDIContracts

/// Exact explicit precision options, with no CLI-selected numeric defaults.
public struct CoreSpiceCLIPrecisionOptions: Codable, Sendable, Hashable {
    public let maximumProgramBytes: UInt64
    public let maximumMappingBytes: UInt64
    public let arenaBytes: UInt64
    public let maximumWorkUnits: UInt64
    public let minimumPrecisionBits: UInt32
    public let maximumPrecisionBits: UInt32
    public let startupTimeoutNanoseconds: UInt64
    public let evaluationTimeoutNanoseconds: UInt64
    public let cleanupTimeoutNanoseconds: UInt64
    public let pollNanoseconds: UInt64

    init(_ value: OSDIPrecisionOptions) {
        maximumProgramBytes = value.maximumProgramBytes; maximumMappingBytes = value.maximumMappingBytes
        arenaBytes = value.arenaBytes; maximumWorkUnits = value.maximumWorkUnits
        minimumPrecisionBits = value.minimumPrecisionBits; maximumPrecisionBits = value.maximumPrecisionBits
        startupTimeoutNanoseconds = value.startupTimeoutNanoseconds; evaluationTimeoutNanoseconds = value.evaluationTimeoutNanoseconds
        cleanupTimeoutNanoseconds = value.cleanupTimeoutNanoseconds; pollNanoseconds = value.pollNanoseconds
    }
    func checked() throws -> OSDIPrecisionOptions {
        try .init(maximumProgramBytes: maximumProgramBytes, maximumMappingBytes: maximumMappingBytes,
            arenaBytes: arenaBytes, maximumWorkUnits: maximumWorkUnits,
            minimumPrecisionBits: minimumPrecisionBits, maximumPrecisionBits: maximumPrecisionBits,
            startupTimeoutNanoseconds: startupTimeoutNanoseconds, evaluationTimeoutNanoseconds: evaluationTimeoutNanoseconds,
            cleanupTimeoutNanoseconds: cleanupTimeoutNanoseconds, pollNanoseconds: pollNanoseconds)
    }
}

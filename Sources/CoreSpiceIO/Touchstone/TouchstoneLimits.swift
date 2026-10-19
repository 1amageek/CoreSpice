/// Caller-controlled operational ceilings, independent of network physics.
public struct TouchstoneLimits: Sendable {
    public var maximumInputBytes: UInt64
    public var maximumOutputBytes: UInt64
    public var maximumRetainedBytes: UInt64
    public var maximumTokens: UInt64
    public var maximumLineBytes: Int
    public var maximumTokenBytes: Int
    public var maximumPorts: Int
    public var maximumFrequencyPoints: Int

    public init(
        maximumInputBytes: UInt64 = 64 * 1024 * 1024,
        maximumOutputBytes: UInt64 = 256 * 1024 * 1024,
        maximumRetainedBytes: UInt64 = 256 * 1024 * 1024,
        maximumTokens: UInt64 = 8 * 1024 * 1024,
        maximumLineBytes: Int = 1024 * 1024,
        maximumTokenBytes: Int = 256,
        maximumPorts: Int = 256,
        maximumFrequencyPoints: Int = 1_000_000
    ) {
        self.maximumInputBytes = maximumInputBytes
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumRetainedBytes = maximumRetainedBytes
        self.maximumTokens = maximumTokens
        self.maximumLineBytes = maximumLineBytes
        self.maximumTokenBytes = maximumTokenBytes
        self.maximumPorts = maximumPorts
        self.maximumFrequencyPoints = maximumFrequencyPoints
    }

    func validate() throws {
        guard maximumInputBytes > 0, maximumOutputBytes > 0, maximumRetainedBytes > 0,
              maximumTokens > 0, maximumLineBytes > 0, maximumTokenBytes > 0,
              maximumPorts > 0, maximumFrequencyPoints > 0 else {
            throw TouchstoneError.invalidConfiguration("Touchstone limits must be positive")
        }
    }
}

func touchstoneSum(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
    let (value, overflow) = a.addingReportingOverflow(b)
    guard !overflow else { throw TouchstoneError.invalidData("Storage or count overflow") }
    return value
}

func touchstoneBytes(_ count: Int, _ stride: Int) throws -> UInt64 {
    guard count >= 0, stride >= 0 else { throw TouchstoneError.invalidData("Negative storage count") }
    let (value, overflow) = UInt64(count).multipliedReportingOverflow(by: UInt64(stride))
    guard !overflow else { throw TouchstoneError.invalidData("Storage size overflow") }
    return value
}
